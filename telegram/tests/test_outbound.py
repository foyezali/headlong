from headlong_telegram.outbound import RecentPosts


def test_recent_posts_dedupe_window():
    recent = RecentPosts(window=300)
    assert not recent.is_duplicate("telegram-1-1", "hi", now=0)
    assert recent.is_duplicate("telegram-1-1", "hi", now=100)
    assert not recent.is_duplicate("telegram-1-1", "hi", now=500)
    assert not recent.is_duplicate("telegram-2-2", "hi", now=100)


def test_recent_posts_seen_does_not_record():
    recent = RecentPosts(window=300)
    assert not recent.seen("telegram-1-1", "hi", now=0)
    assert not recent.seen("telegram-1-1", "hi", now=10), "seen() must not record"
    recent.record("telegram-1-1", "hi", now=0)
    assert recent.seen("telegram-1-1", "hi", now=10)
    assert not recent.seen("telegram-1-1", "hi", now=400)


def test_run_delivers_only_chat_sourced_messages(tmp_path, monkeypatch):
    """Only bin/chat speaks for the identity: message steps without
    source:"chat" (a thinker appending raw message steps to the trajectory)
    must not reach Telegram."""
    import threading

    from headlong_telegram import outbound
    from headlong_telegram.config import Config

    steps = [
        # legit reply, stamped by bin/chat
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "content": "real reply", "step_id": "aaa"},
        # forged: thinker-appended, wrong source
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "responder", "content": "forged reply", "step_id": "bbb"},
        # forged: no source at all
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "content": "unstamped reply", "step_id": "ccc"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

    class ApproveAll:
        def is_approved(self, user):
            return True

    cfg = Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", admin_id=1, web_url="http://x", state_dir=tmp_path,
    )
    outbound.run(cfg, FakeBot(), ApproveAll(), threading.Event())

    assert sent == ["real reply"]


import base64
import threading

from headlong_telegram.api import ApiError
from headlong_telegram import outbound
from headlong_telegram.config import Config


def _cfg(tmp_path):
    return Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", admin_id=1, web_url="http://x", state_dir=tmp_path,
    )


def test_forged_source_is_not_posted(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "content": "real reply", "step_id": "aaa"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "responder", "content": "forged reply", "step_id": "bbb"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "content": "unstamped reply", "step_id": "ccc"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert sent == ["real reply"]


def test_file_step_uses_send_document_not_message(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt", "content": "hi",
         "step_id": "ddd"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            docs.append((filename, content, caption))

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert docs == [("note.txt", "hi", None)]
    assert sent == []


def test_png_uses_send_photo(tmp_path, monkeypatch):
    png = b"\x89PNG\r\n\x1a\n" + b"rest"
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat",
         "filename": "fig.png",
         "content_b64": base64.b64encode(png).decode("ascii"),
         "step_id": "fff"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    photos = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_photo(self, chat, content, filename, caption=None):
            photos.append((filename, content, caption))

        def send_document(self, chat, content, filename, caption=None):
            raise AssertionError("png should use send_photo")

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert photos == [("fig.png", png, None)]
    assert sent == []


def test_send_photo_retries_as_document(tmp_path, monkeypatch):
    png = b"\x89PNG\r\n\x1a\n" + b"rest"
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat",
         "filename": "fig.png",
         "content_b64": base64.b64encode(png).decode("ascii"),
         "step_id": "ggg"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    photos = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            raise AssertionError("should not send_message")

        def send_photo(self, chat, content, filename, caption=None):
            photos.append(filename)
            raise ApiError("PHOTO_INVALID")

        def send_document(self, chat, content, filename, caption=None):
            docs.append((filename, content, caption))

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert photos == ["fig.png"]
    assert docs == [("fig.png", png, None)]


def test_group_chat_is_dropped(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-99",
         "source": "chat", "content": "group hi", "step_id": "hhh"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert sent == []

def test_jpeg_uses_send_photo(tmp_path, monkeypatch):
    jpeg = b"\xff\xd8\xff" + b"rest"
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat",
         "filename": "shot.jpg",
         "content_b64": base64.b64encode(jpeg).decode("ascii"),
         "step_id": "jpg1"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    photos = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_photo(self, chat, content, filename, caption=None):
            photos.append((filename, content, caption))

        def send_document(self, chat, content, filename, caption=None):
            raise AssertionError("jpeg should use send_photo")

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert photos == [("shot.jpg", jpeg, None)]
    assert sent == []


def test_file_send_failure_falls_back_to_notice(tmp_path, monkeypatch):
    import threading

    from headlong_telegram import outbound
    from headlong_telegram.api import ApiError

    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt", "content": "hi",
         "step_id": "fail1"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            raise ApiError("upload rejected")

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert sent == ["(failed to deliver file note.txt)"]


def test_undecodable_file_falls_back_to_notice(tmp_path, monkeypatch):
    import threading

    from headlong_telegram import outbound

    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt",
         "content": "[file: note.txt]", "content_b64": "@@@bad@@@",
         "step_id": "badb64"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            docs.append(filename)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert docs == []
    assert sent == ["(failed to deliver file note.txt)"]


def test_identical_file_steps_are_suppressed(tmp_path, monkeypatch):
    import threading

    from headlong_telegram import outbound

    body = b"same-bytes"
    b64 = base64.b64encode(body).decode("ascii")
    other = b"different-bytes"
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt", "content_b64": b64,
         "step_id": "f1"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt", "content_b64": b64,
         "step_id": "f2"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt",
         "content_b64": base64.b64encode(other).decode("ascii"),
         "step_id": "f3"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            docs.append((filename, content, caption))

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert docs == [("note.txt", body, None), ("note.txt", other, None)]
    assert sent == []


def test_invalid_file_content_does_not_stop_later_replies(tmp_path, monkeypatch):
    import threading

    from headlong_telegram import outbound

    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "bad.bin",
         "content": {"x": "y"}, "step_id": "badobj"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "content": "later reply", "step_id": "okmsg"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []
    docs = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

        def send_document(self, chat, content, filename, caption=None):
            docs.append(filename)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert docs == []
    assert sent == ["(failed to deliver file bad.bin)", "later reply"]



def test_slack_reaction_step_is_not_posted(tmp_path, monkeypatch):
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "reaction": "thumbsup", "content": ":thumbsup:",
         "step_id": "r1"},
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "content": "later reply", "step_id": "t1"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert sent == ["later reply"]


# --- delivery notices (design/outbound_delivery.md, part 7) -------------------

def _drive(tmp_path, monkeypatch, steps, bot, approve=True):
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    class Allow:
        def is_approved(self, user):
            return approve
    cfg = Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", admin_id=1, web_url="http://x", state_dir=tmp_path,
    )
    outbound.run(cfg, bot, Allow(), threading.Event())


def _msg(step_id, to, content="hello"):
    return {"type": "message", "from": "audel", "to": to, "source": "chat",
            "content": content, "step_id": step_id}


class Bot:
    def __init__(self, fail=False):
        self.sent = []
        self.fail = fail

    def send_message(self, chat, text, html=False):
        if self.fail:
            raise ApiError("chat not found")
        self.sent.append(text)


def test_delivered_notice_names_the_message_step(tmp_path, monkeypatch, notices):
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "hi")], bot)
    assert bot.sent == ["hi"]
    n = notices[0]
    assert n["type"] == "delivery" and n["source"] == "telegram-bridge" and n["transport"] == "telegram"
    assert n["status"] == "delivered" and n["trigger_step"] == "m1" and n["chat"] == "1"
    assert n["content"] == "delivered to telegram-1-1"


def test_send_failure_is_a_failed_notice(tmp_path, monkeypatch, notices):
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1")], Bot(fail=True))
    assert notices[0]["status"] == "failed" and "chat not found" in notices[0]["reason"]


def test_unapproved_and_group_and_malformed_are_failed_notices(tmp_path, monkeypatch, notices):
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1")], bot, approve=False)
    _drive(tmp_path, monkeypatch, [_msg("m2", "telegram-1-2"), _msg("m3", "telegram-bogus")], bot)
    assert bot.sent == []
    assert [n["trigger_step"] for n in notices] == ["m1", "m2", "m3"]
    assert "allowlist" in notices[0]["reason"]
    assert "group" in notices[1]["reason"]
    assert "unknown telegram address form" in notices[2]["reason"]


def test_other_transports_get_no_notice(tmp_path, monkeypatch, notices):
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "slack-U1-C1"), _msg("m2", "pwa-andy")], bot)
    assert bot.sent == [] and notices == []


def test_failed_send_does_not_poison_the_retry(tmp_path, monkeypatch, notices):
    """is_duplicate() records as it checks, so a failed send left the text
    looking delivered and the retry was refused as a duplicate of something
    that never went out (fixed 2026-11-23, matching the Slack bridge)."""
    class Flaky(Bot):
        def __init__(self):
            super().__init__()
            self.calls = 0

        def send_message(self, chat, text, html=False):
            self.calls += 1
            # The first message fails on both the HTML attempt and its plain
            # fallback, so nothing at all reaches the chat.
            if self.calls <= 2:
                raise ApiError("rate limited")
            return super().send_message(chat, text, html=html)

    bot = Flaky()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "hello"), _msg("m2", "telegram-1-1", "hello")], bot)
    assert bot.sent == ["hello"]
    assert [n["status"] for n in notices] == ["failed", "delivered"]


def test_duplicate_is_a_skipped_notice(tmp_path, monkeypatch, notices):
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "x"), _msg("m2", "telegram-1-1", "x")], bot)
    assert bot.sent == ["x"]
    assert [n["status"] for n in notices] == ["delivered", "skipped"]


def test_unwritable_trajectory_disables_notices_after_one_error(tmp_path, monkeypatch, notices, caplog):
    calls = []

    def denied(serve_root, traj_path, step):
        calls.append(step)
        raise PermissionError("not writable")
    monkeypatch.setattr(outbound, "append_step", denied)
    bot = Bot()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "a"), _msg("m2", "telegram-1-1", "b")], bot)
    assert bot.sent == ["a", "b"]
    assert len(calls) == 1
    assert sum("delivery notices disabled" in r.message for r in caplog.records) == 1


def test_run_survives_unreadable_trajectory(tmp_path, monkeypatch):
    """A PermissionError while opening or following the trajectory must not
    end the outbound thread: it retries and delivers once the file is
    readable again (2026-09-22: the mind chmod 700'd its own trajectory dir
    and every reply for 19 hours stayed in the log)."""
    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "content": "late but delivered", "step_id": "aaa"},
    ]
    calls = {"find": 0, "follow": 0}

    def find_trajectory(_d):
        calls["find"] += 1
        if calls["find"] < 3:
            raise PermissionError(13, "Permission denied", str(tmp_path / "t.jsonl"))
        return tmp_path / "t.jsonl"

    def follow(*_a, **_k):
        calls["follow"] += 1
        if calls["follow"] == 1:
            raise PermissionError(13, "Permission denied", str(tmp_path / "t.jsonl"))
        yield from steps

    monkeypatch.setattr(outbound.mindlog, "find_trajectory", find_trajectory)
    monkeypatch.setattr(outbound.mindlog, "follow", follow)
    monkeypatch.setattr(outbound, "RETRY_SECS", 0.01)

    sent = []

    class FakeBot:
        def send_message(self, chat, text, html=False):
            sent.append(text)

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), FakeBot(), ApproveAll(), threading.Event())
    assert sent == ["late but delivered"]
    assert calls == {"find": 4, "follow": 2}


def test_run_stops_while_trajectory_is_unreadable(tmp_path, monkeypatch):
    """The retry loop honours stop_event, so a bridge shutdown never hangs
    on a trajectory it cannot read."""
    stop = threading.Event()

    def find_trajectory(_d):
        stop.set()
        raise PermissionError(13, "Permission denied", "t.jsonl")

    monkeypatch.setattr(outbound.mindlog, "find_trajectory", find_trajectory)
    monkeypatch.setattr(outbound, "RETRY_SECS", 0.01)
    outbound.run(_cfg(tmp_path), object(), object(), stop)


# --- one retry for a send that never reached Telegram ------------------------

import httpx

from headlong_telegram.api import ApiError


def _retry_now(monkeypatch):
    monkeypatch.setattr(outbound, "RETRY_SEND_SECS", 0.0)


class FlakyConnect(Bot):
    """Fails the first send with a connection error, then behaves."""

    def __init__(self, exc=None, failures=1):
        super().__init__()
        self.attempts = 0
        self.exc = exc or httpx.ConnectError("Connection reset by peer")
        self.failures = failures

    def send_message(self, chat, text, html=False):
        self.attempts += 1
        if self.attempts <= self.failures:
            raise self.exc
        self.sent.append(text)


def test_connect_error_before_send_is_retried_once(tmp_path, monkeypatch, notices):
    """2026-11-23: a TLS handshake reset at 15:26 lost a message because the
    send path tried exactly once. A connection that never came up is safe to
    repeat, so the message now goes out on the second attempt."""
    _retry_now(monkeypatch)
    bot = FlakyConnect()
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "hello")], bot)
    assert bot.attempts == 2
    assert bot.sent == ["hello"]
    assert notices[0]["status"] == "delivered"


def test_connect_error_twice_is_a_failed_notice(tmp_path, monkeypatch, notices):
    _retry_now(monkeypatch)
    bot = FlakyConnect(failures=2)
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "hello")], bot)
    assert bot.attempts == 2, "exactly one retry, never a loop"
    assert bot.sent == []
    assert notices[0]["status"] == "failed" and "ConnectError" in notices[0]["reason"]


def test_read_error_is_not_retried(tmp_path, monkeypatch, notices):
    """A read timeout or protocol error can fire after Telegram accepted the
    message, and sendMessage is not idempotent, so those are recorded failed
    rather than repeated."""
    _retry_now(monkeypatch)
    bot = FlakyConnect(exc=httpx.ReadTimeout("timed out"))
    _drive(tmp_path, monkeypatch, [_msg("m1", "telegram-1-1", "hello")], bot)
    assert bot.attempts == 1
    assert bot.sent == []
    assert notices[0]["status"] == "failed" and "ReadTimeout" in notices[0]["reason"]


def test_file_send_retries_a_connect_error(tmp_path, monkeypatch, notices):
    _retry_now(monkeypatch)
    docs = []
    attempts = {"n": 0}

    class DocBot:
        def send_message(self, chat, text, html=False):
            raise AssertionError("file step should not send text")

        def send_document(self, chat, content, filename, caption=None):
            attempts["n"] += 1
            if attempts["n"] == 1:
                raise httpx.ConnectTimeout("connect timed out")
            docs.append(filename)

    steps = [
        {"type": "message", "from": "audel", "to": "telegram-1-1",
         "source": "chat", "filename": "note.txt", "content": "hi",
         "step_id": "ddd"},
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    class ApproveAll:
        def is_approved(self, user):
            return True

    outbound.run(_cfg(tmp_path), DocBot(), ApproveAll(), threading.Event())
    assert attempts["n"] == 2
    assert docs == ["note.txt"]
    assert notices[0]["status"] == "delivered"
