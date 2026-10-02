"""Alpaca PAPER-trading client for TradingAgents (added in 1.5.0). Standard library only.

Safety rules built into this file:
  * The trading host is hard-coded to https://paper-api.alpaca.markets. Any other address is refused
    (check_trading_url) and redirects are never followed, so the keys cannot be sent anywhere else.
  * Prices come from the Alpaca market-data host https://data.alpaca.markets (also hard-coded).
  * Nothing here runs by itself: an order is only sent when order() / auto_sell.py is called on purpose.
  * The Key ID and Secret are read from .env (next to this file), are sent only as the two Alpaca headers,
    and are removed from every message this module returns (redact()).

Command line (used by ta-app.ps1; every command prints exactly ONE JSON line on stdout and exits 0):
    python alpaca_client.py test [--use-env]
    python alpaca_client.py quote  --symbol AAPL
    python alpaca_client.py position --symbol AAPL
    python alpaca_client.py order  --symbol AAPL --side buy --qty 10 --type market
    python alpaca_client.py order  --symbol AAPL --side buy --qty 10 --type limit --limit-price 187.50
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENV_FILE = HERE / ".env"

PAPER_HOST = "paper-api.alpaca.markets"
PAPER_BASE_URL = "https://" + PAPER_HOST
DATA_HOST = "data.alpaca.markets"
DATA_BASE_URL = "https://" + DATA_HOST

ENV_KEY_ID = "ALPACA_KEY_ID"
ENV_SECRET = "ALPACA_SECRET_KEY"
ENV_AUTOSELL = "ALPACA_AUTOSELL_ENABLED"

TIMEOUT_SECONDS = 15
MAX_QTY = 1000000

# Order statuses (docs.alpaca.markets/docs/orders-at-alpaca). "Waiting" ones have not traded yet.
STATUS_WAITING = ("new", "accepted", "pending_new", "accepted_for_bidding", "held")
STATUS_PLAIN = {
    "new": "waiting to be filled",
    "accepted": "accepted, waiting to be filled",
    "pending_new": "being sent to the exchange",
    "accepted_for_bidding": "accepted, waiting to be filled",
    "held": "waiting to be filled",
    "partially_filled": "partly filled",
    "filled": "filled",
    "done_for_day": "done for today",
    "canceled": "canceled",
    "expired": "expired without trading",
    "rejected": "rejected by Alpaca",
    "suspended": "suspended",
}


# ---------------------------------------------------------------------------------------------
# errors and redaction
# ---------------------------------------------------------------------------------------------
class AlpacaError(Exception):
    """An Alpaca (or network) problem. .plain is the message to show to the person using the app."""

    def __init__(self, status: int, api_message: str, plain: str):
        super().__init__(plain)
        self.status = status
        self.api_message = api_message
        self.plain = plain


def redact(text, *secrets) -> str:
    """Replace every secret (Key ID, Secret) found in text with ***."""
    out = str(text)
    for s in secrets:
        if s and len(str(s)) >= 4:
            out = out.replace(str(s), "***")
    return out


def plain_error(status: int, api_message: str) -> str:
    """Plain-English text for an Alpaca HTTP error. `api_message` is Alpaca's own "message" field."""
    msg = (api_message or "").strip()
    low = msg.lower()
    if status == 0:
        return ("Could not reach Alpaca. Check your internet connection (and firewall or antivirus), "
                "then try again.")
    if status == 401:
        return ("Alpaca did not accept your Key ID and Secret (401). Open Alpaca settings and paste the "
                "PAPER account keys again. Live-account keys will not work here.")
    if status == 403:
        if "buying power" in low or ("insufficient" in low and "power" in low):
            return "Not enough buying power in the paper account for this order (403). Try fewer shares."
        if low in ("forbidden", "forbidden.", "unauthorized", "unauthorized.") or "not authorized" in low:
            return ("Alpaca says these keys are not allowed to do this (403). Check that they are PAPER "
                    "account keys and that trading is not blocked on the account.")
        if "qty" in low or "shares" in low or "available" in low:
            return ("Not enough shares available to sell (403). Some of them may be tied up in another "
                    "open order. " + msg)
        return "Alpaca refused this (403): " + (msg or "no reason given") + "."
    if status == 404:
        return ("Alpaca could not find that (404). The ticker may not be tradable there, or you do not "
                "hold it.")
    if status == 422:
        return "Alpaca could not accept this order (422): " + (msg or "invalid order details") + "."
    if status == 429:
        return "Alpaca says there were too many requests (429). Wait a minute and try again."
    if status >= 500:
        return "Alpaca had a problem on its side (" + str(status) + "). Try again in a few minutes."
    return "Alpaca returned an error (" + str(status) + "): " + (msg or "no details") + "."


# ---------------------------------------------------------------------------------------------
# addresses and keys
# ---------------------------------------------------------------------------------------------
def _check_url(url: str, host: str) -> str:
    p = urllib.parse.urlsplit(str(url).strip())
    try:
        port = p.port
    except ValueError:
        port = -1
    ok = (p.scheme == "https" and (p.hostname or "").lower() == host and port in (None, 443)
          and not p.username and not p.password and p.path in ("", "/") and not p.query and not p.fragment)
    if not ok:
        raise ValueError("Refusing to use '" + str(url) + "'. Only https://" + host + " is allowed.")
    return "https://" + host


def check_trading_url(url: str) -> str:
    """Returns the paper trading base URL, or raises ValueError for any other address."""
    return _check_url(url, PAPER_HOST)


def check_credentials(key_id: str, secret: str) -> None:
    """Raises ValueError (plain English) if the Key ID or Secret cannot be real keys."""
    for label, v in (("Key ID", key_id), ("Secret", secret)):
        v = v or ""
        if not v:
            raise ValueError("Please enter the " + label + ".")
        if re.search(r"\s", v):
            raise ValueError("The " + label + " has a space in it. Paste it again exactly as Alpaca shows it.")
        if not re.fullmatch(r"[\x21-\x7e]{16,128}", v):
            raise ValueError("The " + label + " does not look right (it should be 16 or more letters and digits "
                             "with no spaces).")


def read_env_values(path) -> dict:
    """Minimal .env reader (NAME=value, optional quotes, last line wins). Never raises for a missing file."""
    vals = {}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return vals
    for line in text.splitlines():
        m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", line)
        if m:
            vals[m.group(1)] = m.group(2).strip("\"'")
    return vals


def load_credentials(env_path=ENV_FILE, use_environ=False):
    """(key_id, secret) from .env (or, for "Test connection" before saving, from the process environment).
    Raises AlpacaError with a plain message when they are not saved."""
    if use_environ:
        v = {k: os.environ.get(k, "") for k in (ENV_KEY_ID, ENV_SECRET)}
    else:
        v = read_env_values(env_path)
    key_id, secret = v.get(ENV_KEY_ID, ""), v.get(ENV_SECRET, "")
    if not key_id or not secret:
        raise AlpacaError(-1, "", "Alpaca keys are not saved yet. Open 'Alpaca settings' and add your paper "
                                  "Key ID and Secret.")
    return key_id, secret


# ---------------------------------------------------------------------------------------------
# symbols
# ---------------------------------------------------------------------------------------------
_US_TICKER = re.compile(r"^[A-Z]{1,5}(?:[.-][A-Z])?$")


def to_alpaca_symbol(ticker: str) -> str:
    """TradingAgents ticker -> Alpaca symbol (BRK-B -> BRK.B). Raises ValueError if not a US stock/ETF."""
    t = (ticker or "").strip().upper()
    if not _US_TICKER.match(t):
        raise ValueError("Paper trading works for US stocks and ETFs only (like AAPL, NVDA or SPY). '" + t
                         + "' is not supported in this version.")
    return t.replace("-", ".")


def from_alpaca_symbol(symbol: str) -> str:
    """Alpaca symbol -> TradingAgents ticker (BRK.B -> BRK-B)."""
    return (symbol or "").strip().upper().replace(".", "-")


# ---------------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------------
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def default_transport(method, url, headers, body, timeout):
    """Returns (status, body bytes). Network failures raise (handled by the caller)."""
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


class AlpacaClient:
    def __init__(self, key_id: str, secret: str, base_url: str = PAPER_BASE_URL, transport=None):
        check_credentials(key_id, secret)
        self.base_url = check_trading_url(base_url)
        self._key_id = key_id
        self._secret = secret
        self._transport = transport or default_transport

    def _call(self, method, base, path, params=None, body=None):
        url = base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        headers = {"APCA-API-KEY-ID": self._key_id, "APCA-API-SECRET-KEY": self._secret,
                   "Accept": "application/json", "User-Agent": "TradingAgents-Windows/1.5"}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            status, raw = self._transport(method, url, headers, data, TIMEOUT_SECONDS)
        except Exception as exc:  # noqa: BLE001 - any network problem
            raise AlpacaError(0, redact(exc, self._key_id, self._secret), plain_error(0, "")) from None
        text = raw.decode("utf-8", "replace") if isinstance(raw, (bytes, bytearray)) else str(raw or "")
        try:
            payload = json.loads(text) if text.strip() else None
        except ValueError:
            payload = None
        if status < 200 or status >= 300:
            api_msg = ""
            if isinstance(payload, dict):
                api_msg = str(payload.get("message") or "")
            elif text and len(text) < 300:
                api_msg = text
            api_msg = redact(api_msg, self._key_id, self._secret)
            raise AlpacaError(status, api_msg, plain_error(status, api_msg))
        return payload

    def _trading(self, method, path, params=None, body=None):
        return self._call(method, self.base_url, path, params, body)

    # ---- endpoints (docs.alpaca.markets/reference) ----
    def get_account(self) -> dict:
        return self._trading("GET", "/v2/account") or {}

    def get_positions(self) -> list:
        return self._trading("GET", "/v2/positions") or []

    def get_position(self, symbol: str):
        """The open position, or None when you do not hold it."""
        try:
            return self._trading("GET", "/v2/positions/" + urllib.parse.quote(symbol, safe=""))
        except AlpacaError as e:
            if e.status == 404:
                return None
            raise

    def get_clock(self) -> dict:
        return self._trading("GET", "/v2/clock") or {}

    def get_latest_price(self, symbol: str):
        """Latest trade price from the IEX feed (free for paper accounts), or None if there is none."""
        data = self._call("GET", DATA_BASE_URL, "/v2/stocks/trades/latest",
                          {"symbols": symbol, "feed": "iex"})
        try:
            return float(((data or {}).get("trades") or {})[symbol]["p"])
        except (KeyError, TypeError, ValueError):
            return None

    def submit_order(self, symbol, side, qty, order_type="market", limit_price=None) -> dict:
        """POST /v2/orders. Always time_in_force=day, never extended_hours (market orders cannot use it)."""
        side = (side or "").lower()
        order_type = (order_type or "").lower()
        if side not in ("buy", "sell"):
            raise ValueError("Side must be buy or sell.")
        if order_type not in ("market", "limit"):
            raise ValueError("Order type must be market or limit.")
        body = {"symbol": symbol, "qty": _format_qty(qty), "side": side, "type": order_type,
                "time_in_force": "day", "client_order_id": "tradingagents-" + uuid.uuid4().hex}
        if order_type == "limit":
            body["limit_price"] = _format_price(limit_price)
        return self._trading("POST", "/v2/orders", body=body) or {}


def _format_qty(qty) -> str:
    text = str(qty).strip()
    if not re.fullmatch(r"\d+(\.\d{1,9})?", text):
        raise ValueError("Number of shares must be a plain number, like 10.")
    d = float(text)
    if d <= 0 or d > MAX_QTY:
        raise ValueError("Number of shares must be more than 0 and at most " + str(MAX_QTY) + ".")
    return str(int(text)) if "." not in text else text


def _format_price(price) -> str:
    try:
        p = float(str(price).strip())
    except (TypeError, ValueError):
        raise ValueError("Limit price must be a number.") from None
    if not (0 < p <= 1000000):
        raise ValueError("Limit price must be more than 0.")
    return ("%.2f" % p) if p >= 1 else ("%.4f" % p)


# ---------------------------------------------------------------------------------------------
# plain-English summaries
# ---------------------------------------------------------------------------------------------
def describe_order(order: dict, market_open=None) -> str:
    """One short paragraph for the app / log: what was placed and what happens next."""
    side = str(order.get("side", "")).upper()
    qty = order.get("qty") or order.get("filled_qty") or "?"
    sym = order.get("symbol", "?")
    otype = str(order.get("type") or order.get("order_type") or "market").lower()
    status = str(order.get("status", "")).lower()
    what = "%s %s %s" % (side, qty, sym)
    if otype == "limit" and order.get("limit_price"):
        what += " at a limit of $" + str(order.get("limit_price"))
    else:
        what += " at the market price"
    oid = str(order.get("id", "unknown"))
    if status == "rejected":
        return "Alpaca rejected the order: " + what + ". Order id: " + oid + "."
    text = "%s. Status: %s. Order id: %s." % (what, STATUS_PLAIN.get(status, status or "unknown"), oid)
    if status in STATUS_WAITING and market_open is False:
        text += (" The market is closed right now, so Alpaca keeps the order and sends it when the market "
                 "opens (9:30 AM Eastern, regular trading days). It is a day order and will not trade "
                 "before then.")
    elif status in STATUS_WAITING and otype == "limit":
        text += " It trades only if the price reaches your limit."
    return text


# ---------------------------------------------------------------------------------------------
# command line (JSON, one line)
# ---------------------------------------------------------------------------------------------
def _out(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=True), flush=True)


def run_command(args, transport=None, env_path=ENV_FILE) -> dict:
    try:
        key_id, secret = load_credentials(env_path, use_environ=bool(getattr(args, "use_env", False)))
        client = AlpacaClient(key_id, secret, transport=transport)
    except AlpacaError as e:
        return {"ok": False, "error": e.plain, "status": e.status}
    except ValueError as e:
        return {"ok": False, "error": str(e), "status": -1}
    try:
        if args.cmd == "test":
            a = client.get_account()
            blocked = bool(a.get("trading_blocked")) or bool(a.get("account_blocked"))
            msg = "Connected to your Alpaca PAPER account. Status: %s. Buying power: $%s." % (
                a.get("status", "unknown"), a.get("buying_power", "?"))
            if blocked:
                msg += " WARNING: trading is blocked on this account."
            return {"ok": True, "status": a.get("status"), "buying_power": a.get("buying_power"),
                    "cash": a.get("cash"), "blocked": blocked, "message": msg}
        symbol = to_alpaca_symbol(args.symbol)
        if args.cmd == "quote":
            try:
                return {"ok": True, "symbol": symbol, "price": client.get_latest_price(symbol)}
            except AlpacaError as e:
                if e.status in (0, 401):
                    raise
                # a price problem must not block trading: the window just shows no estimate
                return {"ok": True, "symbol": symbol, "price": None, "note": e.plain}
        if args.cmd == "position":
            p = client.get_position(symbol)
            if p is None:
                return {"ok": True, "symbol": symbol, "held": False, "qty": "0"}
            return {"ok": True, "symbol": symbol, "held": True, "qty": str(p.get("qty", "0")),
                    "qty_available": str(p.get("qty_available", p.get("qty", "0"))),
                    "side": p.get("side"), "avg_entry_price": p.get("avg_entry_price")}
        if args.cmd == "order":
            if args.side == "sell":
                p = client.get_position(symbol)
                if p is None:
                    return {"ok": False, "error": "You do not hold " + symbol + " in the paper account, so "
                            "there is nothing to sell."}
            order = client.submit_order(symbol, args.side, args.qty, args.type, args.limit_price)
            market_open = None
            try:
                market_open = bool(client.get_clock().get("is_open"))
            except AlpacaError:
                pass
            return {"ok": True, "id": order.get("id"), "status": order.get("status"),
                    "message": describe_order(order, market_open)}
        return {"ok": False, "error": "Unknown command."}
    except AlpacaError as e:
        return {"ok": False, "error": e.plain, "status": e.status}
    except ValueError as e:
        return {"ok": False, "error": redact(e, key_id, secret)}


def main(argv=None, transport=None, env_path=ENV_FILE) -> int:
    p = argparse.ArgumentParser(description="Alpaca paper-trading helper for TradingAgents")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("test").add_argument("--use-env", action="store_true",
                                        help="read the keys from the environment (test before saving)")
    for name in ("quote", "position"):
        sp = sub.add_parser(name)
        sp.add_argument("--symbol", required=True)
    o = sub.add_parser("order")
    o.add_argument("--symbol", required=True)
    o.add_argument("--side", required=True, choices=("buy", "sell"))
    o.add_argument("--qty", required=True)
    o.add_argument("--type", choices=("market", "limit"), default="market")
    o.add_argument("--limit-price")
    args = p.parse_args(argv)
    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:  # noqa: BLE001
        pass
    if args.cmd == "order" and args.type == "limit" and not args.limit_price:
        _out({"ok": False, "error": "Please enter a limit price."})
        return 0
    _out(run_command(args, transport=transport, env_path=env_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
