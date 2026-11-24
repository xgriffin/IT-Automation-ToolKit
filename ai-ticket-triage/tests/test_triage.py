import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import triage  # noqa: E402

KB = triage.load_kb(ROOT / "kb")


def run(subject, description, requester="test.user@contoso.com"):
    return triage.triage_rules({"id": "T1", "requester": requester, "subject": subject,
                                "description": description}, KB)


def test_phishing_is_security_p1_even_if_password_mentioned():
    r = run("Suspicious email", "Got a phishing email asking for my password, I clicked a link")
    assert r.category == "Security"
    assert r.priority == "P1"


def test_lockout_matches_account_kb():
    r = run("Locked out", "I'm locked out after too many wrong password attempts")
    assert r.category == "Account/Access"
    assert r.kb_article == "KB001-account-lockout"


def test_widespread_outage_is_p1():
    r = run("Wifi down", "The wifi is down for everyone and the production line is down")
    assert r.category == "Network"
    assert r.priority == "P1"


def test_low_urgency_request_is_p4():
    r = run("Monitor", "When you get a chance I would like a second monitor. No rush.")
    assert r.category == "Hardware"
    assert r.priority == "P4"


def test_unknown_text_is_general_with_no_kb():
    r = run("Hello", "Quick thing about the break room coffee machine")
    assert r.category == "General"
    assert r.kb_article == ""


def test_reply_uses_first_name_and_never_asks_for_password():
    r = run("Locked out", "locked out of my account", requester="sam.porter@contoso.com")
    assert r.suggested_reply.startswith("Hi Sam,")
    assert "send me your password" not in r.suggested_reply.lower()


def test_full_run_writes_outputs(tmp_path):
    code = triage.main([str(ROOT / "sample_data" / "tickets.csv"), "--out", str(tmp_path)])
    assert code == 0
    assert (tmp_path / "triage_results.csv").exists()
    assert "Ticket Triage Summary" in (tmp_path / "triage_summary.md").read_text()


def test_dead_laptop_matches_power_kb():
    r = run("Laptop won't turn on", "My laptop won't turn on even when plugged into the charger")
    assert r.category == "Hardware"
    assert r.kb_article == "KB007-laptop-no-power"


class _FakeBlock:
    type = "text"

    def __init__(self, text):
        self.text = text


class _FakeClient:
    """Stands in for anthropic.Anthropic() so AI mode can be tested without an API key."""

    def __init__(self, reply):
        self._reply = reply
        self.messages = self

    def create(self, **kwargs):
        assert "Knowledge base" in kwargs["system"]
        return type("Resp", (), {"content": [_FakeBlock(self._reply)]})()


def test_ai_mode_parses_json_and_validates_kb_id():
    reply = ('Here you go: {"category": "Network", "priority": "P2", "kb_article": "KB999-made-up", '
             '"suggested_reply": "Hi!", "reasoning": "vpn"}')
    r = triage.triage_ai({"id": "9", "requester": "a@b.com", "subject": "VPN", "description": "vpn down"},
                         KB, _FakeClient(reply), "test-model")
    assert (r.category, r.priority, r.mode) == ("Network", "P2", "ai")
    assert r.kb_article == ""  # hallucinated KB ids are dropped
