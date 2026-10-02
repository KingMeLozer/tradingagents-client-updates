"""Morning auto-sell for the Alpaca PAPER account (added in 1.5.0).

What it does, in order:
  1. Asks Alpaca (paper account) which stocks you hold.
  2. Runs the normal TradingAgents analysis (run_analysis.py) for each one.
  3. If the final rating is SELL or UNDERWEIGHT, sends a market order to sell the whole position.
     Anything else (BUY, OVERWEIGHT, HOLD, REVIEW, or an analysis that failed) is left alone.
  4. Writes a plain-text summary to reports\\auto-sell-YYYY-MM-DD.txt (the date is the New York date).

Orders are "day" market orders. Sent before 9:30 AM Eastern, Alpaca accepts them and releases them at the
open (market orders cannot be used in extended hours), so the log says "queued for the open", not "sold".

Usage:
    python auto_sell.py --dry-run          # analyse and report, send NO orders
    python auto_sell.py --now              # real run right now (the "Run auto-sell now" button)
    python auto_sell.py --scheduled        # what the Windows Scheduled Task runs (weekday/time/holiday checks)

Exit code: 0 finished, 1 finished but something failed, 2 did not run (guard), 3 set-up problem (keys).
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import alpaca_client as ac  # noqa: E402

SELL_RATINGS = ("SELL", "UNDERWEIGHT")
LOCK_STALE_SECONDS = 8 * 3600
ANALYSIS_TIMEOUT_SECONDS = 30 * 60
WINDOW_START_MIN = 7 * 60 + 30     # scheduled runs only between 07:30 and 15:30 New York time (covers a 1 hour clock drift)
WINDOW_END_MIN = 15 * 60 + 30


# ---------------------------------------------------------------------------------------------
# New York time (zoneinfo when the PC has tz data, otherwise the fixed US daylight-saving rule)
# ---------------------------------------------------------------------------------------------
def _nth_sunday(year: int, month: int, n: int) -> datetime.date:
    d = datetime.date(year, month, 1)
    d += datetime.timedelta(days=(6 - d.weekday()) % 7)      # first Sunday
    return d + datetime.timedelta(weeks=n - 1)


def et_from_utc_rule(utc: datetime.datetime) -> datetime.datetime:
    """US Eastern time from a UTC datetime by rule: DST from 2nd Sunday of March 2:00 to 1st Sunday of Nov 2:00."""
    utc = utc.replace(tzinfo=None)
    start = datetime.datetime.combine(_nth_sunday(utc.year, 3, 2), datetime.time(7, 0))   # 02:00 EST = 07:00 UTC
    end = datetime.datetime.combine(_nth_sunday(utc.year, 11, 1), datetime.time(6, 0))    # 02:00 EDT = 06:00 UTC
    offset = -4 if start <= utc < end else -5
    return utc + datetime.timedelta(hours=offset)


def to_et(utc: datetime.datetime) -> datetime.datetime:
    """Naive New York wall-clock datetime for an aware-or-naive UTC datetime."""
    if utc.tzinfo is not None:
        utc = utc.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    try:
        from zoneinfo import ZoneInfo
        aware = utc.replace(tzinfo=datetime.timezone.utc).astimezone(ZoneInfo("America/New_York"))
        return aware.replace(tzinfo=None)
    except Exception:  # noqa: BLE001 - no tz database on this PC
        return et_from_utc_rule(utc)


# ---------------------------------------------------------------------------------------------
# log
# ---------------------------------------------------------------------------------------------
class RunLog:
    def __init__(self, path: Path, clock=None):
        self.path = Path(path)
        self.lines = []
        self._clock = clock or (lambda: to_et(datetime.datetime.now(datetime.timezone.utc)))

    def say(self, msg: str) -> None:
        line = "%s  %s" % (self._clock().strftime("%H:%M:%S"), msg)
        self.lines.append(line)
        print(line, flush=True)
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass

    def raw(self, text: str) -> None:
        self.lines.append(text)
        print(text, flush=True)
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(text + "\n")
        except OSError:
            pass


def log_path_for(reports_dir: Path, now_utc: datetime.datetime) -> Path:
    return Path(reports_dir) / ("auto-sell-%s.txt" % to_et(now_utc).strftime("%Y-%m-%d"))


# ---------------------------------------------------------------------------------------------
# guards
# ---------------------------------------------------------------------------------------------
def scheduled_guard(now_utc: datetime.datetime, clock: dict):
    """(ok, reason). Scheduled runs only happen on a New York weekday between 07:30 and 15:30 on a trading day."""
    et = to_et(now_utc)
    if et.weekday() >= 5:
        return False, "It is the weekend in New York (%s)." % et.strftime("%A")
    minutes = et.hour * 60 + et.minute
    if minutes < WINDOW_START_MIN or minutes > WINDOW_END_MIN:
        return False, ("It is %s in New York, outside the 7:30 AM to 3:30 PM window for the morning run."
                       % et.strftime("%I:%M %p").lstrip("0"))
    if clock and clock.get("is_open") is False:
        try:
            nxt = datetime.datetime.fromisoformat(str(clock.get("next_open")))
            if nxt.date() != et.date():
                return False, "The market is closed today (holiday), next open is %s." % clock.get("next_open")
        except (TypeError, ValueError):
            pass
    return True, ""


class Lock:
    """One auto-sell at a time (a second click or a late scheduled run while one is going would double-sell)."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.held = False

    def acquire(self) -> bool:
        try:
            if self.path.exists() and time.time() - self.path.stat().st_mtime > LOCK_STALE_SECONDS:
                self.path.unlink()
            fd = os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            return False
        except OSError:
            return True          # cannot use a lock file here; do not block the run
        with os.fdopen(fd, "w") as fh:
            fh.write("%d %s\n" % (os.getpid(), datetime.datetime.now().isoformat()))
        self.held = True
        return True

    def release(self) -> None:
        if self.held:
            try:
                self.path.unlink()
            except OSError:
                pass
            self.held = False


# ---------------------------------------------------------------------------------------------
# the analysis (run_analysis.py in a child process, same as the app does)
# ---------------------------------------------------------------------------------------------
def python_for_child() -> str:
    exe = sys.executable
    if exe.lower().endswith("pythonw.exe"):
        cand = exe[:-len("pythonw.exe")] + "python.exe"
        if os.path.exists(cand):
            return cand
    return exe


def run_analysis(ticker: str, reports_dir: Path, timeout: int = ANALYSIS_TIMEOUT_SECONDS) -> dict:
    """{'rating': 'SELL'|..., 'txt': path, 'error': ''}. Never raises."""
    cmd = [python_for_child(), str(HERE / "run_analysis.py"), "--ticker", ticker,
           "--reports-dir", str(reports_dir), "--no-notepad", "--json-progress"]
    env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    flags = 0x08000000 if sys.platform == "win32" else 0   # CREATE_NO_WINDOW
    try:
        cp = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                            timeout=timeout, cwd=str(HERE), env=env, stdin=subprocess.DEVNULL,
                            creationflags=flags)
    except subprocess.TimeoutExpired:
        return {"rating": "", "txt": "", "error": "The analysis took longer than %d minutes and was stopped." % (timeout // 60)}
    except OSError as e:
        return {"rating": "", "txt": "", "error": "The analysis could not start: %s" % e}
    return parse_analysis_output(cp.stdout or "", cp.returncode, cp.stderr or "")


def parse_analysis_output(stdout: str, code: int, stderr: str = "") -> dict:
    done, err = None, ""
    for line in stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            evt = json.loads(line)
        except ValueError:
            continue
        if evt.get("event") == "done":
            done = evt
        elif evt.get("event") == "error":
            err = str(evt.get("message", ""))
    if done and code == 0:
        return {"rating": str(done.get("rating", "")).upper(), "txt": str(done.get("txt", "")), "error": ""}
    if not err:
        tail = " ".join([l for l in stderr.splitlines() if l.strip()][-2:])
        err = ("The analysis stopped with an error. " + tail).strip() if tail else "The analysis did not finish."
    return {"rating": "", "txt": "", "error": err}


# ---------------------------------------------------------------------------------------------
# main flow
# ---------------------------------------------------------------------------------------------
def run(args, client=None, analyzer=None, now_utc=None, env_path=None, reports_dir=None, lock_path=None) -> int:
    now_utc = now_utc or datetime.datetime.now(datetime.timezone.utc)
    reports_dir = Path(reports_dir or HERE / "reports")
    env_path = env_path or (HERE / ".env")
    analyzer = analyzer or (lambda t: run_analysis(t, reports_dir))
    log = RunLog(log_path_for(reports_dir, now_utc), clock=lambda: to_et(now_utc))
    mode = "DRY RUN (no orders will be sent)" if args.dry_run else "REAL RUN (paper account)"
    log.raw("")
    log.raw("=" * 70)
    log.raw("Auto-sell  %s ET  -  %s%s" % (to_et(now_utc).strftime("%Y-%m-%d %H:%M"), mode,
                                           "  [scheduled]" if args.scheduled else ""))
    log.raw("Alpaca PAPER account only (%s). Research tool, not financial advice." % ac.PAPER_BASE_URL)
    log.raw("=" * 70)

    values = ac.read_env_values(env_path)
    if args.scheduled and values.get(ac.ENV_AUTOSELL, "") != "1":
        log.say("Skipped: the morning auto-sell is switched off in Alpaca settings.")
        return 2
    lock = Lock(lock_path or (HERE / "auto_sell.lock"))
    if not lock.acquire():
        log.say("Skipped: another auto-sell is already running.")
        return 2
    try:
        if client is None:
            try:
                key_id, secret = ac.load_credentials(env_path)
                client = ac.AlpacaClient(key_id, secret)
            except ac.AlpacaError as e:
                log.say("STOPPED: " + e.plain)
                return 3
            except ValueError as e:
                log.say("STOPPED: " + str(e))
                return 3
        return _run_locked(args, client, analyzer, now_utc, log)
    finally:
        lock.release()


def _run_locked(args, client, analyzer, now_utc, log: RunLog) -> int:
    clock = {}
    try:
        clock = client.get_clock()
    except ac.AlpacaError as e:
        if e.status in (0, 401, 403):
            log.say("STOPPED: " + e.plain)
            return 3
        log.say("Could not read the market clock (%s). Continuing." % e.plain)
    if args.scheduled:
        ok, why = scheduled_guard(now_utc, clock)
        if not ok:
            log.say("Skipped: " + why)
            return 2
    if clock.get("is_open") is False:
        log.say("The market is closed right now. Sell orders are day orders: Alpaca holds them and sends them "
                "at the next open (9:30 AM Eastern).")
    try:
        positions = client.get_positions()
    except ac.AlpacaError as e:
        log.say("STOPPED: could not read your positions. " + e.plain)
        return 3 if e.status in (0, 401, 403) else 1

    sold = kept = problems = skipped = 0
    if not positions:
        log.say("No open positions in the paper account. Nothing to do.")
    else:
        log.say("Open positions: " + ", ".join(str(p.get("symbol")) for p in positions))
    results = []
    for p in positions:
        sym = str(p.get("symbol", "?"))
        qty = str(p.get("qty", "0"))
        if str(p.get("asset_class", "us_equity")) != "us_equity" or str(p.get("side", "long")) != "long":
            log.say("%s: skipped (only long US stock/ETF positions are handled)." % sym)
            skipped += 1
            results.append((sym, "skipped"))
            continue
        ticker = ac.from_alpaca_symbol(sym)
        log.say("%s: running the analysis for %s shares (this takes several minutes)..." % (sym, qty))
        res = analyzer(ticker)
        rating = str(res.get("rating", "")).upper()
        if res.get("error") or not rating:
            log.say("%s: ANALYSIS FAILED, position left as it is. %s" % (sym, res.get("error", "")))
            problems += 1
            results.append((sym, "analysis failed"))
            continue
        log.say("%s: final rating %s%s" % (sym, rating, ("  (report: %s)" % res["txt"]) if res.get("txt") else ""))
        if rating not in SELL_RATINGS:
            log.say("%s: KEEP (%s is not a sell rating)." % (sym, rating))
            kept += 1
            results.append((sym, "kept (%s)" % rating))
            continue
        try:
            avail = float(str(p.get("qty_available", qty)))
        except ValueError:
            avail = 0.0
        if avail <= 0:
            log.say("%s: SKIPPED, all %s shares are already in an open order." % (sym, qty))
            skipped += 1
            results.append((sym, "already has an open order"))
            continue
        sell_qty = str(p.get("qty_available", qty))
        if args.dry_run:
            log.say("%s: DRY RUN - would sell %s shares at market (rating %s). No order sent." % (sym, sell_qty, rating))
            results.append((sym, "dry run: would sell %s" % sell_qty))
            continue
        try:
            order = client.submit_order(sym, "sell", sell_qty, "market")
        except ac.AlpacaError as e:
            log.say("%s: SELL FAILED. %s" % (sym, e.plain))
            problems += 1
            results.append((sym, "sell failed"))
            continue
        except ValueError as e:
            log.say("%s: SELL FAILED. %s" % (sym, e))
            problems += 1
            results.append((sym, "sell failed"))
            continue
        sold += 1
        log.say("%s: SELL ORDER SENT. %s" % (sym, ac.describe_order(order, clock.get("is_open") if clock else None)))
        results.append((sym, "sell order sent"))

    log.raw("-" * 70)
    log.say("SUMMARY: %d position(s) checked. Sell orders sent: %d. Kept: %d. Skipped: %d. Problems: %d.%s" % (
        len(positions), sold, kept, skipped, problems,
        "  (dry run: nothing was sent)" if args.dry_run else ""))
    for sym, what in results:
        log.raw("   %-8s %s" % (sym, what))
    return 1 if problems else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Morning auto-sell for the Alpaca paper account")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--scheduled", action="store_true", help="run by the Windows Scheduled Task")
    mode.add_argument("--now", action="store_true", help="real run right now")
    ap.add_argument("--dry-run", action="store_true", help="analyse and report but send no orders")
    args = ap.parse_args(argv)
    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:  # noqa: BLE001
        pass
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
