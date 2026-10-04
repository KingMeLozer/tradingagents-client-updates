import http.server
import json
import threading
import urllib.error

import pytest

import command_center as cc

ENV = {"COMMAND_CENTER_API_URL": "https://app.dudedatdid.com/api/v1/", "COMMAND_CENTER_API_BEARER": "tok-12345678"}


def test_configure_shared_sets_process_only_config():
    env, config = dict(ENV), {"llm_provider": "deepseek", "backend_url": None, "max_tokens": None}
    cc.configure_shared(config, env)
    assert config["llm_provider"] == "openai"
    assert config["backend_url"] == "https://app.dudedatdid.com/api/v1"
    assert config["deep_think_llm"] == "anthropic/claude-sonnet-5.5"
    assert config["quick_think_llm"] == "deepseek/deepseek-v4.1-flash"
    assert config["max_tokens"] == 4096
    assert env["OPENAI_API_KEY"] == "tok-12345678"


@pytest.mark.parametrize("env", [{}, {"COMMAND_CENTER_API_URL": "http://x/api"}, {"COMMAND_CENTER_API_URL": "https://x/api"}])
def test_configure_shared_fails_fast(env):
    with pytest.raises(ValueError):
        cc.configure_shared({}, dict(env))


def test_body_has_only_the_five_fields():
    body = json.loads(cc.build_body("SPY", "2026-10-04", "09:30", "BUY", "text"))
    assert list(body) == ["ticker", "date", "time", "rating", "portfolio_manager"]


@pytest.mark.parametrize("pm", ["x" * 100_000, "é" * 50_000, '"\\\n' * 30_000, "😀" * 30_000])
def test_body_size_cap(pm):
    body = cc.build_body("SPY", "2026-10-04", "09:30", "BUY", pm)
    assert len(body) <= 40_000
    assert json.loads(body)["portfolio_manager"].endswith("[truncated]")


def test_small_body_not_truncated():
    assert json.loads(cc.build_body("SPY", "d", "t", "HOLD", "short"))["portfolio_manager"] == "short"


class _Server:
    """Local server: /redir answers 302 to /target; records every request."""

    def __init__(self, status=201):
        seen = self.seen = []

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                seen.append((self.path, self.headers.get("Authorization"), self.rfile.read(int(self.headers["Content-Length"]))))
                if self.path == "/redir":
                    self.send_response(302)
                    self.send_header("Location", "/target")
                else:
                    self.send_response(status)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

            def log_message(self, *a):
                pass

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_port}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()


def test_redirect_is_refused_and_not_followed():
    s = _Server()
    try:
        with pytest.raises(urllib.error.HTTPError) as e:
            cc.post_json(s.url + "/redir", b"{}", "secret")
        assert e.value.code == 302
        assert [p for p, _, _ in s.seen] == ["/redir"]
    finally:
        s.close()


def test_post_json_sends_bearer():
    s = _Server()
    try:
        assert cc.post_json(s.url + "/ok", b"{}", "secret")[0] == 201
        assert s.seen[0][1] == "Bearer secret"
    finally:
        s.close()


def test_sync_report_failures_return_false_and_never_raise(caplog):
    assert cc.sync_report("SPY", "d", "t", "BUY", "pm", {}) is False  # not configured
    assert cc.sync_report("bad ticker!", "d", "t", "BUY", "pm", dict(ENV)) is False
    assert "tok-12345678" not in caplog.text


def test_sync_report_success_and_non_201(monkeypatch):
    calls = []
    monkeypatch.setattr(cc, "post_json", lambda url, body, token, timeout=0: calls.append((url, body, token)) or (201, b"{}"))
    assert cc.sync_report("spy", "2026-10-04", "09:30", "BUY", "pm", dict(ENV)) is True
    url, body, token = calls[0]
    assert url == "https://app.dudedatdid.com/api/v1/trading/reports" and token == "tok-12345678"
    assert json.loads(body)["ticker"] == "SPY"
    monkeypatch.setattr(cc, "post_json", lambda *a, **k: (200, b"{}"))
    assert cc.sync_report("SPY", "d", "t", "BUY", "pm", dict(ENV)) is False
