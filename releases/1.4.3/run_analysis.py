"""Run one TradingAgents analysis and save a readable report.

Called by run.ps1. Reads the settings the installer wrote to .env (next to
this file: AI provider, model ids, API key), runs
TradingAgentsGraph(...).propagate for today's date, prints the final decision,
and saves the full report as a .txt file.

Usage:
    python run_analysis.py --ticker SPY --reports-dir "C:\\Users\\me\\AppData\\Local\\TradingAgents\\reports"

Also writes a sibling .json next to the .txt report (read by ta-app.ps1, the results window).
With --json-progress the program prints one JSON object per line on stdout instead of the
human-readable text, and with --no-notepad it does not open the report; ta-app.ps1 uses both.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
import logging
import traceback
import warnings
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENV_FILE = HERE / ".env"
ERROR_LOG = HERE / "last-error-log.txt"
RUN_LOG = HERE / "last-run-log.txt"

# Same crypto suffixes the repo's CLI uses to pick the crypto pipeline
# (cli/prompts.py, CRYPTO_SUFFIXES).
CRYPTO_SUFFIXES = ("-USD", "-USDT", "-USDC", "-BTC", "-ETH")

# Friendly names for the provider ids TradingAgents accepts (llm_clients/api_key_env.py).
PROVIDER_NAMES = {
    "anthropic": "Anthropic (Claude)", "openai": "OpenAI", "google": "Google (Gemini)",
    "xai": "xAI (Grok)", "openrouter": "OpenRouter", "deepseek": "DeepSeek", "mistral": "Mistral",
    "qwen": "Qwen (Alibaba)", "qwen-cn": "Qwen (Alibaba, China)", "glm": "GLM (Z.AI)",
    "glm-cn": "GLM (BigModel, China)", "minimax": "MiniMax", "minimax-cn": "MiniMax (China)",
    "kimi": "Kimi (Moonshot)", "groq": "Groq", "nvidia": "NVIDIA NIM", "azure": "Azure OpenAI",
    "bedrock": "AWS Bedrock", "ollama": "Ollama (local)", "openai_compatible": "custom OpenAI-compatible server",
}

# Where to manage keys/billing, used in error messages.
KEY_URLS = {
    "anthropic": "https://console.anthropic.com", "openai": "https://platform.openai.com",
    "google": "https://aistudio.google.com", "xai": "https://console.x.ai",
    "openrouter": "https://openrouter.ai", "deepseek": "https://platform.deepseek.com",
    "mistral": "https://console.mistral.ai", "qwen": "https://modelstudio.console.alibabacloud.com",
    "glm": "https://z.ai", "minimax": "https://platform.minimax.io", "kimi": "https://platform.moonshot.ai",
}

# DeepSeek retired its old model names "deepseek-chat" / "deepseek-reasoner" on 2026-07-24
# (api-docs.deepseek.com/updates). Current names: deepseek-v4-pro (deep thinking) and deepseek-flash (fast).
DEEPSEEK_URL = "https://api.deepseek.com"
DEEPSEEK_MODEL_RENAMES = {
    "deepseek-reasoner": "deepseek-v4-pro",
    "deepseek-chat": "deepseek-flash",
    "deepseek-v4-flash": "deepseek-flash",
}


def apply_provider_defaults(values: dict, environ) -> dict:
    """For provider "deepseek": swap retired model names for current ones and fill in the base URL.

    Writes into ``environ`` (the process environment, which TradingAgents reads) and never into .env.
    Returns {variable: new value} for what it changed. Does nothing for other providers.
    """
    if (values.get("TRADINGAGENTS_LLM_PROVIDER") or "").strip().lower() != "deepseek":
        return {}
    changes = {}
    for var in ("TRADINGAGENTS_DEEP_THINK_LLM", "TRADINGAGENTS_QUICK_THINK_LLM"):
        new = DEEPSEEK_MODEL_RENAMES.get((values.get(var) or "").strip().lower())
        if new:
            environ[var] = new
            changes[var] = new
    if not (environ.get("TRADINGAGENTS_LLM_BACKEND_URL") or "").strip():
        environ["TRADINGAGENTS_LLM_BACKEND_URL"] = DEEPSEEK_URL
        changes["TRADINGAGENTS_LLM_BACKEND_URL"] = DEEPSEEK_URL
    return changes


def key_fix_hint(provider: str, key_url: str) -> str:
    """Where to fix a bad or missing key: the app's AI settings for DeepSeek, the installer otherwise."""
    if provider == "deepseek":
        return f"Open the TradingAgents window, click 'AI settings', and paste a valid key from {key_url}"
    return f"Run the installer again and paste a valid key from {key_url}"


# Set by --json-progress: stdout carries one JSON object per line (read by ta-app.ps1) instead of text.
JSON_MODE = False

RATINGS = ("BUY", "OVERWEIGHT", "HOLD", "UNDERWEIGHT", "SELL", "REVIEW")

RATING_MEANING = {
    "Buy": "BUY - the agents recommend buying / opening a position.",
    "Overweight": "OVERWEIGHT - lean BUY: add to or hold more than a normal position.",
    "Hold": "HOLD - keep what you have; no new buying or selling.",
    "Underweight": "UNDERWEIGHT - lean SELL: trim, hold less than a normal position.",
    "Sell": "SELL - the agents recommend selling / exiting the position.",
    "REVIEW": "REVIEW - the final answer had no clear rating. Read the Portfolio "
              "Manager section of the report yourself.",
}


def emit(obj: dict) -> None:
    """One JSON object per line (ASCII only, so no console encoding can break it)."""
    print(json.dumps(obj, ensure_ascii=True), flush=True)


def fail(message: str, code: int = 2) -> None:
    if JSON_MODE:
        emit({"event": "error", "message": message, "code": code})
        sys.exit(code)
    print()
    print("=" * 70)
    print("PROBLEM: " + message)
    print("=" * 70)
    sys.exit(code)


def load_settings() -> dict:
    """Load .env into the environment (it wins over any older system variables)."""
    if not ENV_FILE.is_file():
        fail(f"Settings file not found: {ENV_FILE}\n"
             "Run '1 - Install (double-click).bat' again to set up your provider and API key.")
    from dotenv import dotenv_values, load_dotenv

    load_dotenv(ENV_FILE, override=True)
    values = dotenv_values(ENV_FILE)

    missing = [k for k in ("TRADINGAGENTS_LLM_PROVIDER", "TRADINGAGENTS_DEEP_THINK_LLM",
                           "TRADINGAGENTS_QUICK_THINK_LLM")
               if not (values.get(k) or "").strip()]
    if missing:
        fail("These settings are missing from " + str(ENV_FILE) + ": " + ", ".join(missing)
             + "\nRun '1 - Install (double-click).bat' again.")

    apply_provider_defaults(values, os.environ)
    provider = values["TRADINGAGENTS_LLM_PROVIDER"].strip().lower()
    # The repo's own provider -> key-variable table (single source of truth).
    from tradingagents.llm_clients.api_key_env import PROVIDER_API_KEY_ENV

    if provider not in PROVIDER_API_KEY_ENV:
        fail(f"TRADINGAGENTS_LLM_PROVIDER in .env is '{provider}', which TradingAgents does not know. "
             "Run the installer again and pick a provider from the menu.")
    key_var = PROVIDER_API_KEY_ENV[provider]
    if key_var and not (values.get(key_var) or "").strip():
        hint = ("Open the TradingAgents window, click 'AI settings' and paste the key."
                if provider == "deepseek" else "Run '1 - Install (double-click).bat' again and paste the key.")
        fail(f"The API key for {provider_name(provider)} ({key_var}) is missing from {ENV_FILE}.\n" + hint)
    values["_provider"] = provider
    return values


def provider_name(provider: str) -> str:
    return PROVIDER_NAMES.get(provider, provider)


class Progress:
    """Prints one short line each time an agent calls the AI model."""

    def __init__(self):
        from langchain_core.callbacks import BaseCallbackHandler

        start = time.time()
        counter = {"n": 0}

        class _Handler(BaseCallbackHandler):
            def on_chat_model_start(self, serialized, messages, **kwargs):
                counter["n"] += 1
                meta = kwargs.get("metadata") or {}
                who = meta.get("langgraph_node") or "Agent"
                elapsed = int(time.time() - start)
                if JSON_MODE:
                    emit({"event": "step", "n": counter["n"], "node": str(who),
                          "stage": stage_for_node(str(who)), "elapsed": elapsed})
                    return
                print(f"  [{elapsed // 60:02d}:{elapsed % 60:02d}] step {counter['n']:>3}: "
                      f"{who} is working...", flush=True)

        self.handler = _Handler()


def explain_api_error(exc: BaseException, provider: str, key_url: str) -> str | None:
    """Plain-English message for a provider API error, or None if it is not one.

    Works for every provider: the Anthropic and OpenAI SDKs (also used for xAI,
    DeepSeek, OpenRouter, ...) raise errors carrying ``status_code``; the Google
    SDK's carry ``code``. Walks the cause chain because LangChain sometimes wraps
    the SDK error.
    """
    name = provider_name(provider)
    seen = set()
    e = exc
    while e is not None and id(e) not in seen:
        seen.add(id(e))
        text = str(e)
        cls = type(e).__name__
        status = getattr(e, "status_code", None)
        if not isinstance(status, int):
            status = getattr(e, "code", None)
        if "APIConnectionError" in cls or "ConnectError" in cls or "ConnectionError" in cls:
            return (f"Could not reach {name}'s servers. Check your internet connection "
                    "(or firewall/antivirus) and try again.")
        if isinstance(status, int):
            if status == 401:
                return f"{name} rejected your API key (401). " + key_fix_hint(provider, key_url)
            if status == 403:
                return f"Your {name} account is not allowed to use this model (403). {text}"
            if status == 404:
                return (f"{name} does not recognise the model name (404). Send this message to the "
                        "person who set this up. " + text)
            if status == 429:
                low = text.lower()
                if "quota" in low or "billing" in low or "credit" in low or "insufficient" in low:
                    return (f"Your {name} account has no credit or its quota is used up (429). "
                            f"Check billing at {key_url} and try again.")
                return (f"{name} rate limit reached (429). Wait a few minutes and try again. "
                        "New accounts have low limits that rise as you use the API.")
            if status == 400 and ("credit" in text.lower() or "balance" in text.lower()):
                return (f"Your {name} account is out of credit. Add credit at {key_url} and try again.")
            if status == 402:
                return f"Your {name} account is out of credit (402). Add credit at {key_url} and try again."
            if status >= 400:
                return f"{name} returned an error ({status}): {text}"
        e = e.__cause__ or e.__context__
    return None


def stage_for_node(node: str) -> str:
    """Map a LangGraph node name ("Market Analyst", "Bull Researcher", ...) to a GUI step id.

    Returns "" for nodes that are not a visible step (message clearing, tools, unknown names).
    """
    n = re.sub(r"[^a-z]", "", (node or "").lower())
    if "portfolio" in n:
        return "portfolio"
    if "researchmanager" in n or "investmentjudge" in n:
        return "research_manager"
    if "bull" in n or "bear" in n:
        return "debate"
    if "aggressive" in n or "conservative" in n or "neutral" in n or "risk" in n:
        return "risk"
    if "trader" in n:
        return "trader"
    if "market" in n:
        return "market"
    if "social" in n or "sentiment" in n:
        return "sentiment"
    if "news" in n:
        return "news"
    if "fundamental" in n:
        return "fundamentals"
    return ""


def _text(value) -> str:
    """A state value as clean text ("" for None / non-text)."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, (list, tuple)):
        return "\n\n".join(_text(v) for v in value if _text(v))
    content = getattr(value, "content", None)  # a LangChain message
    if isinstance(content, str):
        return content.strip()
    return str(value).strip()


def _first(state, *keys) -> str:
    if not isinstance(state, dict):
        return ""
    for k in keys:
        t = _text(state.get(k))
        if t:
            return t
    return ""


def normalize_rating(signal) -> str:
    """BUY / OVERWEIGHT / HOLD / UNDERWEIGHT / SELL, or REVIEW when there is no clear rating."""
    r = str(signal or "").strip().upper()
    return r if r in RATINGS else "REVIEW"


def extract_sections(final_state: dict) -> dict:
    """Each agent's text from final_state, as plain strings ("" when a part did not run).

    Keys read (TradingAgents agent_states.py): market_report, sentiment_report, news_report,
    fundamentals_report, investment_debate_state{bull_history, bear_history, judge_decision, history},
    investment_plan, trader_investment_plan, risk_debate_state{aggressive_history, conservative_history,
    neutral_history, judge_decision, history}, final_trade_decision. Missing keys are simply empty.
    """
    fs = final_state if isinstance(final_state, dict) else {}
    deb = fs.get("investment_debate_state")
    risk = fs.get("risk_debate_state")
    deb = deb if isinstance(deb, dict) else {}
    risk = risk if isinstance(risk, dict) else {}
    return {
        "market": _first(fs, "market_report"),
        "sentiment": _first(fs, "sentiment_report", "social_report"),
        "news": _first(fs, "news_report"),
        "fundamentals": _first(fs, "fundamentals_report"),
        "bull": _first(deb, "bull_history"),
        "bear": _first(deb, "bear_history"),
        "debate_history": _first(deb, "history"),
        "debate_verdict": _first(deb, "judge_decision"),
        "research_manager": _first(fs, "investment_plan"),
        "trader": _first(fs, "trader_investment_plan", "trader_investment_decision"),
        "risk_aggressive": _first(risk, "aggressive_history"),
        "risk_conservative": _first(risk, "conservative_history"),
        "risk_neutral": _first(risk, "neutral_history"),
        "risk_history": _first(risk, "history"),
        "risk_verdict": _first(risk, "judge_decision"),
    }


def build_report_dict(final_state: dict, signal, *, ticker: str, trade_date: str, time_hm: str,
                      provider: str, deep_model: str, quick_model: str, duration_seconds: int,
                      txt_name: str, is_crypto: bool = False) -> dict:
    """The content of the sibling .json (schema 1). Pure function: no file or network access."""
    fs = final_state if isinstance(final_state, dict) else {}
    rating = normalize_rating(signal)
    return {
        "schema": 1,
        "ticker": ticker,
        "date": trade_date,
        "time": time_hm,
        "provider": provider,
        "provider_name": provider_name(provider),
        "models": {"deep": deep_model, "quick": quick_model},
        "rating": rating,
        "meaning": RATING_MEANING.get(signal, RATING_MEANING.get(rating, str(signal))),
        "portfolio_manager": _text(fs.get("final_trade_decision")),
        "sections": extract_sections(fs),
        "duration_seconds": int(duration_seconds),
        "is_crypto": bool(is_crypto),
        "txt_report": txt_name,
    }


def write_report_json(path: Path, report: dict) -> None:
    """Write the .json atomically (a half-written file is never seen by the history list)."""
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def safe_name(ticker: str) -> str:
    return re.sub(r"[^A-Za-z0-9.-]", "_", ticker)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ticker", default="SPY")
    parser.add_argument("--reports-dir")
    parser.add_argument("--no-open", action="store_true", help="do not open the report")
    parser.add_argument("--no-notepad", action="store_true",
                        help="same as --no-open (used by the results window)")
    parser.add_argument("--json-progress", action="store_true",
                        help="print one JSON line per step on stdout (used by the results window)")
    parser.add_argument("--check", action="store_true",
                        help="only verify settings and build the agent graph (no AI calls)")
    args = parser.parse_args()
    global JSON_MODE
    JSON_MODE = args.json_progress
    no_open = args.no_open or args.no_notepad
    if not args.check and not args.reports_dir:
        parser.error("--reports-dir is required")

    # Never crash on a character the Windows console cannot show.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except Exception:
            pass

    # Library warnings (vendor retries, structured-output fallbacks) go to a log
    # file instead of the console, so the window shows only progress + result.
    logging.basicConfig(filename=str(RUN_LOG), filemode="w", encoding="utf-8",
                        level=logging.WARNING,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.captureWarnings(True)
    warnings.simplefilter("default")

    settings = load_settings()
    # Keep TradingAgents' own raw report tree inside the app folder too (it used the user profile folder).
    os.environ.setdefault("TRADINGAGENTS_RESULTS_DIR", str(HERE / "reports" / "raw"))

    # Import only after .env is loaded: DEFAULT_CONFIG reads the TRADINGAGENTS_*
    # variables at import time (tradingagents/default_config.py).
    from tradingagents.dataflows.symbols import normalize_symbol
    from tradingagents.default_config import DEFAULT_CONFIG
    from tradingagents.graph.trading_graph import TradingAgentsGraph

    config = DEFAULT_CONFIG.copy()
    provider = settings["_provider"]
    if config["llm_provider"].lower() != provider:
        fail(f"Configuration did not pick up the provider from .env ({provider}). "
             "Run the installer again.")
    key_url = KEY_URLS.get(provider, "your provider's website")

    if args.check:
        # Building the graph creates the model clients but sends no requests.
        TradingAgentsGraph(debug=False, config=config)
        print(f"Configuration OK: provider={provider} ({provider_name(provider)}), "
              f"deep model={config['deep_think_llm']}, quick model={config['quick_think_llm']}, "
              "FRED key=" + ("yes" if (settings.get("FRED_API_KEY") or "").strip() else "no"))
        return 0

    ticker = normalize_symbol(args.ticker.strip() or "SPY")
    trade_date = datetime.date.today().isoformat()
    is_crypto = ticker.endswith(CRYPTO_SUFFIXES)
    analysts = ["market", "social", "news"] if is_crypto else ["market", "social", "news", "fundamentals"]

    if JSON_MODE:
        emit({"event": "start", "ticker": ticker, "date": trade_date, "crypto": is_crypto,
              "analysts": analysts, "provider_name": provider_name(provider),
              "models": {"deep": config["deep_think_llm"], "quick": config["quick_think_llm"]}})
    else:
        print()
        print(f"Ticker:        {ticker}{'  (crypto)' if is_crypto else ''}")
        print(f"Date:          {trade_date}")
        print(f"AI provider:   {provider_name(provider)}")
        print(f"Models:        {config['deep_think_llm']} (final decisions), "
              f"{config['quick_think_llm']} (analysts)")
        print("Macro data:    " + ("FRED key found" if (settings.get("FRED_API_KEY") or "").strip()
                                  else "no FRED key (macro data skipped - optional)"))
        print()
        print("Running the analyst team. This usually takes several minutes;")
        print("each line below is one step. Do not close this window.")
        print()

    run_started = time.time()
    progress = Progress()
    try:
        ta = TradingAgentsGraph(selected_analysts=analysts, debug=False, config=config,
                                callbacks=[progress.handler])
        final_state, signal = ta.propagate(ticker, trade_date,
                                           asset_type="crypto" if is_crypto else "stock")
    except KeyboardInterrupt:
        fail("Stopped by you (Ctrl+C). Nothing was saved.", 130)
    except Exception as exc:  # noqa: BLE001 - we explain, log, and exit non-zero
        ERROR_LOG.write_text(traceback.format_exc(), encoding="utf-8")
        friendly = explain_api_error(exc, provider, key_url)
        fail((friendly or f"The analysis stopped with an error: {exc}")
             + f"\n(Technical details saved to {ERROR_LOG} and {RUN_LOG})")

    # Save the repo's own report tree, then build one readable file for the Desktop.
    complete_md = ta.save_reports(final_state, ticker)
    full_report = Path(complete_md).read_text(encoding="utf-8")
    meaning = RATING_MEANING.get(signal, str(signal))
    pm_text = (final_state.get("final_trade_decision") or "").strip()

    reports_dir = Path(args.reports_dir)
    reports_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%H%M")
    out_path = reports_dir / f"{safe_name(ticker)}_{trade_date}_{stamp}.txt"
    bar = "=" * 70
    out_path.write_text(
        "\n".join([
            bar,
            f"TradingAgents report: {ticker}   date: {trade_date}",
            f"FINAL DECISION: {str(signal).upper()}",
            meaning,
            f"AI provider: {provider_name(provider)} - models: {config['deep_think_llm']} / {config['quick_think_llm']}",
            "Research output only - not financial advice. No trade was placed.",
            bar,
            "",
            "PORTFOLIO MANAGER - FINAL DECISION (the reasoning behind the call)",
            "-" * 70,
            pm_text,
            "",
            bar,
            "FULL REPORT (analysts, bull/bear debate, trader, risk team)",
            bar,
            full_report,
            "",
        ]),
        encoding="utf-8",
    )

    # Sibling .json for the results window. A problem here must never lose the .txt report above.
    json_path = out_path.with_suffix(".json")
    try:
        write_report_json(json_path, build_report_dict(
            final_state, signal, ticker=ticker, trade_date=trade_date,
            time_hm=datetime.datetime.now().strftime("%H:%M"), provider=provider,
            deep_model=str(config["deep_think_llm"]), quick_model=str(config["quick_think_llm"]),
            duration_seconds=int(time.time() - run_started), txt_name=out_path.name,
            is_crypto=is_crypto))
    except Exception:  # noqa: BLE001
        json_path = None
        try:
            with open(RUN_LOG, "a", encoding="utf-8") as fh:
                fh.write("Could not write the .json report:\n" + traceback.format_exc() + "\n")
        except Exception:  # noqa: BLE001
            pass

    if JSON_MODE:
        emit({"event": "done", "ticker": ticker, "date": trade_date, "rating": normalize_rating(signal),
              "json": str(json_path) if json_path else "", "txt": str(out_path),
              "seconds": int(time.time() - run_started)})
        return 0

    print()
    print(bar)
    print(f"  FINAL DECISION for {ticker} on {trade_date}:  {str(signal).upper()}")
    print(f"  {meaning}")
    print(bar)
    print(f"Full report saved to:\n  {out_path}")
    print("(It is opening in Notepad now.)" if not no_open else "")

    if not no_open and sys.platform == "win32":
        subprocess.Popen(["notepad.exe", str(out_path)])
    return 0


if __name__ == "__main__":
    sys.exit(main())
