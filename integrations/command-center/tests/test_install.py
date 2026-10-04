import datetime
import subprocess
from pathlib import Path

import pytest

import install

ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT.parents[1] / "releases" / "1.5.1" / "run_analysis.py"
TOKEN = "tok-abcdef123456"


def test_merge_env_preserves_everything_else():
    src = "# keys\r\nOPENAI_API_KEY=sk-1\r\n\r\nCOMMAND_CENTER_API_URL=old\r\nFRED_API_KEY=f"
    out = install.merge_env(src, {"COMMAND_CENTER_API_URL": "new", "COMMAND_CENTER_API_BEARER": "t"})
    assert out == ("# keys\r\nOPENAI_API_KEY=sk-1\r\n\r\nCOMMAND_CENTER_API_URL=new\r\nFRED_API_KEY=f\r\n"
                   "COMMAND_CENTER_API_BEARER=t\r\n")


def test_merge_env_empty_and_lf():
    assert install.merge_env("", {"A": "1"}) == "A=1\n"
    assert install.merge_env("X=1\n", {"A": "1"}) == "X=1\nA=1\n"


def make_install(tmp_path, run_analysis_bytes):
    d = tmp_path / "TradingAgents"
    d.mkdir()
    (d / "run_analysis.py").write_bytes(run_analysis_bytes)
    (d / ".env").write_text("TRADINGAGENTS_LLM_PROVIDER=deepseek\nDEEPSEEK_API_KEY=keep-me\n")
    return d


def test_install_backs_up_copies_and_writes_env(tmp_path):
    original = b"original\n"
    d = make_install(tmp_path, original)
    backups = install.install(d, TOKEN, force=True, now=datetime.datetime(2026, 10, 4, 12, 0, 0))
    bak = d / "run_analysis.py.bak-20261004-120000"
    assert bak in backups and bak.read_bytes() == original
    assert (d / "run_analysis.py").read_bytes() == (ROOT / "run_analysis.py").read_bytes()
    assert (d / "command_center.py").is_file()
    env = (d / ".env").read_text()
    assert "DEEPSEEK_API_KEY=keep-me" in env and f"COMMAND_CENTER_API_BEARER={TOKEN}" in env
    assert "COMMAND_CENTER_API_URL=https://app.dudedatdid.com/api/v1" in env
    assert (d / ".env.bak-20261004-120000").read_text().count("COMMAND_CENTER") == 0


def test_install_refuses_unknown_base_without_force(tmp_path):
    d = make_install(tmp_path, b"something else\n")
    with pytest.raises(SystemExit):
        install.install(d, TOKEN)
    assert (d / "run_analysis.py").read_bytes() == b"something else\n"


@pytest.mark.skipif(not RELEASE.exists(), reason="signed release not in this checkout")
def test_install_accepts_signed_1_5_1_and_is_rerunnable(tmp_path):
    d = make_install(tmp_path, RELEASE.read_bytes())
    install.install(d, TOKEN)
    install.install(d, TOKEN, now=datetime.datetime(2030, 1, 1))  # patched file is an accepted base too


def test_install_rejects_bad_token_and_non_install(tmp_path):
    d = make_install(tmp_path, b"x")
    with pytest.raises(SystemExit):
        install.install(d, "bad token\nINJECT=1", force=True)
    with pytest.raises(SystemExit):
        install.install(tmp_path / "nope", TOKEN, force=True)


def test_main_prompts_with_hidden_input(tmp_path):
    d = make_install(tmp_path, b"x")
    assert install.main([str(d), "--force"], prompt=lambda msg: TOKEN + "\n") == 0
    assert TOKEN in (d / ".env").read_text()


@pytest.mark.skipif(not RELEASE.exists(), reason="signed release not in this checkout")
def test_patch_only_adds_lines_to_signed_release():
    diff = subprocess.run(["diff", str(RELEASE), str(ROOT / "run_analysis.py")], capture_output=True, text=True).stdout
    assert not [l for l in diff.splitlines() if l.startswith("<")]
    assert "1.5.1" in (ROOT / "run_analysis.py").read_text().splitlines()[0]
