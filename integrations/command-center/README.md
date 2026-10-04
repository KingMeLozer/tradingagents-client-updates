# Command Center integration (optional add-on)

Lets the TradingAgents Windows client use the Command Center shared API instead of your own
provider key, and saves each finished report there too. It is opt-in and does not touch the
signed update feed (`manifest.json`, `releases/`): everything here is a separate folder.

Based on the signed client release **1.5.1** (`run_analysis.py` sha256 `db9624a2...fca3`).

## What it does

When `COMMAND_CENTER_API_URL` and `COMMAND_CENTER_API_BEARER` are both in the install's `.env`:

- **LLM calls** go to `{URL}/chat/completions` (provider `openai` with a custom base URL, so Chat
  Completions) using the token as the API key. Models: deep `anthropic/claude-sonnet-5.5`, quick
  `deepseek/deepseek-v4.1-flash`, `max_tokens` 4096 (upstream forwards `config["max_tokens"]`).
  These are set in the running process only; your `.env` provider settings are not rewritten.
- **After the local report is written**, it posts `ticker, date, time, rating, portfolio_manager`
  (and nothing else) to `{URL}/trading/reports`. `portfolio_manager` is truncated so the body stays
  under 40,000 bytes. No secrets, file paths or broker (Alpaca) data are sent.
- If the upload fails, a short message goes to `last-run-log.txt`; the local report is already saved.
- The token is only ever sent to the configured https URL; redirects are refused.

Without those two variables the client behaves exactly like 1.5.1. `install.py` never runs an
analysis or places an order.

## Install (Windows)

1. Install Python 3 if needed (the client's own `venv\Scripts\python.exe` also works).
2. Download this folder (`integrations/command-center`).
3. Open PowerShell in it and run:
   ```
   python install.py
   ```
   (or `python install.py "D:\path\to\TradingAgents"`; default is `%LOCALAPPDATA%\TradingAgents`).
4. Paste the Command Center token when asked (typing is hidden).

It refuses if `run_analysis.py` is not the signed 1.5.1 (use `--force` only if you know why).
Backups are written next to the originals as `run_analysis.py.bak-YYYYMMDD-HHMMSS` and
`.env.bak-YYYYMMDD-HHMMSS`.

**After "Check for updates":** the updater replaces `run_analysis.py` with the signed version, which
switches the integration off (the client keeps working normally). Run `python install.py` again.

## Rollback

1. Copy `run_analysis.py.bak-<timestamp>` over `run_analysis.py` in the install folder.
2. Delete `command_center.py` there (optional).
3. Remove the two `COMMAND_CENTER_API_*` lines from `.env`, or copy `.env.bak-<timestamp>` over it.

## Tests

```
pip install pytest
python -m pytest integrations/command-center/tests
```
