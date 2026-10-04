"""Command Center shared-API glue for the TradingAgents Windows client (stdlib only).

configure_shared(config): point the LLM at the Command Center API (process-only).
sync_report(...):         upload the 5 report fields; never raises, returns True/False.
"""

import json
import logging
import os
import re
import urllib.error
import urllib.request
from urllib.parse import urlparse

URL_ENV = "COMMAND_CENTER_API_URL"
TOKEN_ENV = "COMMAND_CENTER_API_BEARER"
OPENAI_KEY_ENV = "OPENAI_API_KEY"  # what the provider "openai" client reads (api_key_env.py)

DEEP_MODEL = "anthropic/claude-sonnet-5.5"
QUICK_MODEL = "deepseek/deepseek-v4.1-flash"
MAX_TOKENS = 4096

MAX_BODY_BYTES = 40_000
TRUNCATION_MARK = "\n[truncated]"
TICKER_RE = re.compile(r"^[A-Z0-9.\-]{1,12}$")
TIMEOUT = 20

log = logging.getLogger("command_center")


def _base_url(environ) -> str:
    base = (environ.get(URL_ENV) or "").strip().rstrip("/")
    if urlparse(base).scheme != "https":
        raise ValueError(f"{URL_ENV} must be an https:// URL")
    return base


def _token(environ) -> str:
    token = (environ.get(TOKEN_ENV) or "").strip()
    if not token:
        raise ValueError(f"{TOKEN_ENV} is not set")
    return token


def configure_shared(config: dict, environ=None) -> dict:
    """Route the graph's LLM calls through the Command Center API. Process-only: .env is never written.

    Sets llm_provider "openai" + backend_url (so upstream uses Chat Completions), the deep/quick
    models, and max_tokens (upstream forwards config["max_tokens"] to the chat client).
    Raises ValueError when the URL or token is missing/invalid.
    """
    environ = os.environ if environ is None else environ
    base, token = _base_url(environ), _token(environ)
    environ[OPENAI_KEY_ENV] = token
    config["llm_provider"] = "openai"
    config["backend_url"] = base
    config["deep_think_llm"] = DEEP_MODEL
    config["quick_think_llm"] = QUICK_MODEL
    config["max_tokens"] = MAX_TOKENS
    return config


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: the Authorization header must not leave the configured host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post_json(url: str, body: bytes, token: str, timeout: float = TIMEOUT):
    """POST JSON with the bearer token; redirects raise HTTPError. Returns (status, response bytes)."""
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer " + token,
    })
    opener = urllib.request.build_opener(_NoRedirect)
    with opener.open(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def build_body(ticker: str, date: str, time: str, rating: str, portfolio_manager: str) -> bytes:
    """JSON body with exactly the 5 fields, portfolio_manager truncated so the UTF-8 body is <= 40,000 bytes."""
    def encode(pm: str) -> bytes:
        return json.dumps({"ticker": ticker, "date": date, "time": time, "rating": rating,
                           "portfolio_manager": pm}, ensure_ascii=False).encode("utf-8")

    body = encode(portfolio_manager)
    if len(body) <= MAX_BODY_BYTES:
        return body
    lo, hi = 0, len(portfolio_manager)  # longest prefix that fits (escaping makes byte math non-linear)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if len(encode(portfolio_manager[:mid] + TRUNCATION_MARK)) <= MAX_BODY_BYTES:
            lo = mid
        else:
            hi = mid - 1
    return encode(portfolio_manager[:lo] + TRUNCATION_MARK)


def sync_report(ticker: str, date: str, time: str, rating: str, portfolio_manager: str,
                environ=None) -> bool:
    """Upload one report. Never raises; on any failure logs a short message and returns False."""
    try:
        environ = os.environ if environ is None else environ
        ticker = str(ticker).strip().upper()
        if not TICKER_RE.match(ticker):
            raise ValueError("ticker not accepted by Command Center")
        body = build_body(ticker, str(date), str(time), str(rating), str(portfolio_manager or ""))
        status, _ = post_json(_base_url(environ) + "/trading/reports", body, _token(environ))
        if status != 201:
            raise RuntimeError(f"unexpected HTTP {status}")
        return True
    except urllib.error.HTTPError as exc:
        log.warning("Command Center sync failed: HTTP %s", exc.code)
    except Exception as exc:  # noqa: BLE001 - the local report is already saved; never break the run
        log.warning("Command Center sync failed: %s", type(exc).__name__ + (f": {exc}" if isinstance(exc, ValueError) else ""))
    return False
