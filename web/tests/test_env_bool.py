"""Boolean env knobs: an explicit word decides, and a typo says so.

The old rule was `getenv(NAME, "") not in ("", "0")`, which reads every value
that is not empty or a bare zero as ON. `HEADLONG_WEB_READONLY=false` turned
the dashboard read-only, and a systemd drop-in saying `=no` did too.
"""

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from headlong_web.env import getbool
from headlong_web.server import create_app


@pytest.mark.parametrize("raw", ["1", "true", "TRUE", "yes", "on", " on "])
def test_truthy_words_are_on(monkeypatch, raw):
    monkeypatch.setenv("HEADLONG_TEST_FLAG", raw)
    assert getbool("HEADLONG_TEST_FLAG") is True


@pytest.mark.parametrize("raw", ["0", "false", "False", "no", "off", " 0"])
def test_falsy_words_are_off(monkeypatch, raw):
    monkeypatch.setenv("HEADLONG_TEST_FLAG", raw)
    assert getbool("HEADLONG_TEST_FLAG") is False


def test_unset_and_empty_are_the_default(monkeypatch):
    monkeypatch.delenv("HEADLONG_TEST_FLAG", raising=False)
    assert getbool("HEADLONG_TEST_FLAG") is False
    assert getbool("HEADLONG_TEST_FLAG", default=True) is True
    monkeypatch.setenv("HEADLONG_TEST_FLAG", "")
    assert getbool("HEADLONG_TEST_FLAG") is False


def test_unrecognized_value_warns_and_falls_back(monkeypatch, capsys):
    monkeypatch.setenv("HEADLONG_TEST_FLAG", "nope")
    assert getbool("HEADLONG_TEST_FLAG") is False
    err = capsys.readouterr().err
    assert "HEADLONG_TEST_FLAG" in err and "not a boolean" in err


def test_shellm_twin_is_read(monkeypatch):
    monkeypatch.delenv("HEADLONG_TEST_FLAG", raising=False)
    monkeypatch.setenv("SHELLM_TEST_FLAG", "0")
    assert getbool("HEADLONG_TEST_FLAG", default=True) is False


def test_read_only_false_does_not_lock_the_dashboard(tmp_path, monkeypatch):
    """The reported symptom: an explicit false word used to mean read-only.

    Goes through create_app_from_env on purpose, the factory uvicorn imports,
    so the test fails if the wiring stops reading the variable rather than
    only if getbool itself regresses.
    """
    from headlong_web import create_app_from_env

    monkeypatch.setenv("HEADLONG_WEB_ROOT", str(tmp_path))
    monkeypatch.setenv("HEADLONG_WEB_READONLY", "false")
    monkeypatch.delenv("HEADLONG_WEB_SELF_UPDATE", raising=False)
    client = TestClient(create_app_from_env())
    assert client.get("/api/config").json()["controls_enabled"] is True

    monkeypatch.setenv("HEADLONG_WEB_READONLY", "1")
    client = TestClient(create_app_from_env())
    assert client.get("/api/config").json()["controls_enabled"] is False


def test_read_only_one_locks_controls(tmp_path, monkeypatch):
    monkeypatch.setenv("HEADLONG_WEB_READONLY", "1")
    monkeypatch.delenv("HEADLONG_WEB_SELF_UPDATE", raising=False)
    client = TestClient(create_app(tmp_path, None, read_only=True))
    assert client.get("/api/config").json()["controls_enabled"] is False


def test_self_update_accepts_a_word_and_respects_read_only(tmp_path, monkeypatch):
    monkeypatch.setenv("HEADLONG_WEB_SELF_UPDATE", "true")
    client = TestClient(create_app(tmp_path, None))
    assert client.get("/api/config").json()["self_update_enabled"] is True
    monkeypatch.setenv("HEADLONG_WEB_READONLY", "1")
    client = TestClient(create_app(tmp_path, None, read_only=True))
    assert client.get("/api/config").json()["self_update_enabled"] is False
