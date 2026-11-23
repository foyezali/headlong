"""The persisted thread map must degrade one entry at a time."""

from __future__ import annotations

import json
import logging
import time

import pytest

from headlong_slack import state as state_mod
from headlong_slack.state import ACTIVE_THREAD_TTL, ActiveThreads, Deduper


def test_one_bad_value_does_not_drop_every_thread(tmp_path, caplog):
    """A single non-numeric value used to raise inside one comprehension,
    the except swallowed it, and the whole map came back empty: after a
    restart no thread was active and un-mentioned follow-ups stopped
    reaching the mind with nothing logged."""
    path = tmp_path / "active_threads.json"
    now = time.time()
    path.write_text(json.dumps({"C1:1.1": now, "C2:2.2": "not-a-number", "C3:3.3": now}))
    with caplog.at_level(logging.WARNING):
        threads = ActiveThreads(path)
    assert threads.is_active("C1", "1.1") is True
    assert threads.is_active("C3", "3.3") is True
    assert threads.is_active("C2", "2.2") is False
    assert any("dropping bad entry" in r.message for r in caplog.records)


def test_missing_file_is_empty(tmp_path):
    assert ActiveThreads(tmp_path / "nope.json").is_active("C1", "1.1") is False


def test_non_object_json_is_empty_not_fatal(tmp_path):
    path = tmp_path / "active_threads.json"
    path.write_text("[1, 2, 3]")
    assert ActiveThreads(path).is_active("C1", "1.1") is False


def test_torn_json_is_empty_not_fatal(tmp_path):
    path = tmp_path / "active_threads.json"
    path.write_text('{"C1:1.1": 123, ')
    assert ActiveThreads(path).is_active("C1", "1.1") is False


def test_stale_entry_is_not_active(tmp_path):
    path = tmp_path / "active_threads.json"
    path.write_text(json.dumps({"C1:1.1": time.time() - ACTIVE_THREAD_TTL - 10}))
    assert ActiveThreads(path).is_active("C1", "1.1") is False


def test_deduper_remembers_and_bounds():
    d = Deduper(max_size=2)
    assert d.add("a") is True
    assert d.add("a") is False
    assert d.add("b") is True
    assert d.add("c") is True
    assert d.add("a") is True  # evicted, so it counts as new again
