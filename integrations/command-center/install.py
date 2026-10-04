"""Add the Command Center integration to an existing local TradingAgents install.

Usage:  python install.py [INSTALL_DIR] [--force]
Default INSTALL_DIR: %LOCALAPPDATA%\\TradingAgents (what the client's own scripts use).

Backs up run_analysis.py (and .env) with a timestamp, copies the patched files, asks for the
token (hidden) and writes COMMAND_CENTER_API_URL / COMMAND_CENTER_API_BEARER into .env, keeping
every other line. It never runs an analysis and never places an order.
"""

import argparse
import datetime
import getpass
import hashlib
import os
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FILES = ("run_analysis.py", "command_center.py")
DEFAULT_API_URL = "https://app.dudedatdid.com/api/v1"
# sha256 (line endings normalised to LF) of the signed 1.5.1 run_analysis.py the patch is based on.
UPSTREAM_SHA256 = "552e10dbe8579060e0675cbfba982815e0d6a9730cf6add2616df7fc4a513393"
TOKEN_RE = re.compile(r"^[A-Za-z0-9._~+/=\-]{8,512}$")


def normalized_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def default_install_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA")
    if not base:
        sys.exit("LOCALAPPDATA is not set; pass the install folder as an argument.")
    return Path(base) / "TradingAgents"


def merge_env(text: str, updates: dict) -> str:
    """Set KEY=value lines in .env text: replace an existing KEY line in place, append missing ones.

    Every other line (comments, blanks, other keys) is kept byte-for-byte; CRLF/LF style is preserved.
    """
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines(keepends=True)
    remaining = dict(updates)
    for i, line in enumerate(lines):
        m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if m and m.group(1) in remaining:
            ending = line[len(line.rstrip("\r\n")):] or nl
            lines[i] = f"{m.group(1)}={remaining.pop(m.group(1))}{ending}"
    if remaining:
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] += nl
        lines += [f"{k}={v}{nl}" for k, v in remaining.items()]
    return "".join(lines)


def write_env(env_path: Path, token: str) -> None:
    raw = env_path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    merged = merge_env(text, {"COMMAND_CENTER_API_URL": DEFAULT_API_URL, "COMMAND_CENTER_API_BEARER": token})
    tmp = env_path.with_name(env_path.name + ".tmp")
    tmp.write_bytes((b"\xef\xbb\xbf" if bom else b"") + merged.encode("utf-8"))
    os.replace(tmp, env_path)


def install(install_dir: Path, token: str, force: bool = False, now=None) -> list:
    """Do the install; returns the backup paths. Raises SystemExit with a plain message on problems."""
    target, env_path = install_dir / "run_analysis.py", install_dir / ".env"
    if not target.is_file() or not env_path.is_file():
        sys.exit(f"{install_dir} does not look like a TradingAgents install (run_analysis.py or .env missing).")
    if not TOKEN_RE.match(token):
        sys.exit("The token looks invalid (expected 8-512 characters: letters, digits and . _ ~ + / = -).")
    if not force and normalized_sha256(target) not in (UPSTREAM_SHA256, normalized_sha256(HERE / "run_analysis.py")):
        sys.exit("Your run_analysis.py is not the signed 1.5.1 this patch is based on. Run 'Check for updates' "
                 "first, or use --force if you know what you are doing.")
    stamp = (now or datetime.datetime.now()).strftime("%Y%m%d-%H%M%S")
    backups = []
    for path in (target, env_path, install_dir / "command_center.py"):
        if path.is_file():
            bak = path.with_name(f"{path.name}.bak-{stamp}")
            shutil.copy2(path, bak)
            backups.append(bak)
    for name in FILES:
        shutil.copy2(HERE / name, install_dir / name)
    write_env(env_path, token)
    return backups


def main(argv=None, prompt=getpass.getpass) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("install_dir", nargs="?", type=Path)
    ap.add_argument("--force", action="store_true", help="patch even if run_analysis.py is not the 1.5.1 base")
    args = ap.parse_args(argv)
    install_dir = args.install_dir or default_install_dir()
    token = prompt("Command Center API token (input hidden): ").strip()
    backups = install(install_dir, token, args.force)
    print("Installed Command Center integration into", install_dir)
    for b in backups:
        print("  backup:", b)
    print("Next analysis will use the shared API and upload its report. To undo, see README.md (Rollback).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
