"""The user-id allowlist and its pending-approval queue.

Telegram bots are messageable by anyone on Earth, so the allowlist is the
bridge's whole perimeter: unknown senders never reach the mind log, and
outbound replies are only delivered to approved users' chats. Managed
entirely over Telegram by the admin (/approve, /deny, /revoke, /list).

Persisted as one JSON file in the bridge state dir. In production that dir
is /var/lib/shellm-telegram, owned by the bridge's own system user — the
agent's user must NOT be able to write it, or an injected agent could
approve an attacker itself.

This file is the perimeter, so it is read defensively. The old loader parsed
the whole document in one try/except that swallowed everything: `"denied":
"123456"` (an id hand-written as a string) became the SIX ids 1..6 and was
saved back that way, dropping the real deny; one pending entry with a
non-numeric timestamp dropped EVERY pending entry (so the admin was
re-prompted about senders they had already been told about); `"approved":
[7, 8]` approved nobody; and an unparseable file silently started empty and
was overwritten by the next save. Each element is now read on its own, a bad
one is named and skipped, and nothing is written back that was not understood.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from typing import Any, Callable

log = logging.getLogger(__name__)

# Notify the admin about a given unknown sender at most this often, so a
# stranger can't flood the admin's DMs with approval prompts.
PENDING_NOTIFY_INTERVAL = 24 * 3600


class AllowlistError(RuntimeError):
    """The change could not be persisted. Callers must tell the admin."""


def _as_id(value: Any) -> str | None:
    """A numeric Telegram user id, as a string, or None if this is not one."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return str(value) if value >= 0 else None
    if isinstance(value, str):
        text = value.strip()
        if text.isdigit():
            return text
    return None


class Allowlist:
    def __init__(self, path: Path):
        self._path = path
        self._lock = threading.Lock()
        self._approved: dict[str, str] = {}  # user id -> display label
        self._denied: set[str] = set()
        self._pending: dict[str, dict] = {}  # user id -> {label, last_notified}
        self._approved, self._denied, self._pending = self._load(path)

    # -- reading -------------------------------------------------------------

    @staticmethod
    def _load(path: Path) -> tuple[dict[str, str], set[str], dict[str, dict]]:
        approved: dict[str, str] = {}
        denied: set[str] = set()
        pending: dict[str, dict] = {}
        if not path.is_file():
            return approved, denied, pending
        try:
            text = path.read_text()
        except OSError as exc:
            log.error("allowlist %s could not be read (%s); starting empty", path, exc)
            return approved, denied, pending
        if not text.strip():
            return approved, denied, pending
        try:
            data = json.loads(text)
        except ValueError as exc:
            Allowlist._preserve(path, exc)
            return approved, denied, pending
        if not isinstance(data, dict):
            Allowlist._preserve(path, f"top-level {type(data).__name__}, not an object")
            return approved, denied, pending

        Allowlist._load_approved(data.get("approved", {}), approved)
        Allowlist._load_denied(data.get("denied", []), denied)
        Allowlist._load_pending(data.get("pending", {}), pending)
        return approved, denied, pending

    @staticmethod
    def _preserve(path: Path, reason: Any) -> None:
        """Set a file aside before anything can overwrite it.

        Starting empty on an unreadable allowlist is safe for the perimeter but
        destructive for the admin's work: the next /approve would replace a file
        that might still be recoverable by hand. Rename a copy first.
        """
        backup = path.with_name(f"{path.name}.unreadable-{int(time.time())}")
        try:
            path.replace(backup)
        except OSError:
            log.error("allowlist %s is unreadable (%s) and could not be moved aside; "
                      "starting empty and it may be overwritten", path, reason)
            return
        log.error("allowlist %s is unreadable (%s); moved to %s and starting empty",
                  path, reason, backup)

    @staticmethod
    def _load_approved(raw: Any, approved: dict[str, str]) -> None:
        if isinstance(raw, dict):
            items: list[tuple[Any, Any]] = list(raw.items())
        elif isinstance(raw, list):
            log.warning("allowlist: 'approved' was a list, not a map; reading each "
                        "id with itself as its label")
            items = [(value, None) for value in raw]
        else:
            log.warning("allowlist: 'approved' is %s, not a map; ignoring it",
                        type(raw).__name__)
            return
        for key, label in items:
            uid = _as_id(key)
            if uid is None:
                log.warning("allowlist: dropping approved entry with non-numeric id %r", key)
                continue
            approved[uid] = str(label) if label else uid

    @staticmethod
    def _load_denied(raw: Any, denied: set[str]) -> None:
        if isinstance(raw, str):
            # A hand-edit of one id. Iterating the string would turn 123456 into
            # six denies, which is not what anyone typed.
            log.warning("allowlist: 'denied' was a bare string, reading it as one id")
            values: list[Any] = [raw]
        elif isinstance(raw, list):
            values = raw
        else:
            log.warning("allowlist: 'denied' is %s, not a list; ignoring it",
                        type(raw).__name__)
            return
        for value in values:
            uid = _as_id(value)
            if uid is None:
                log.warning("allowlist: dropping denied entry with non-numeric id %r", value)
                continue
            denied.add(uid)

    @staticmethod
    def _load_pending(raw: Any, pending: dict[str, dict]) -> None:
        if not isinstance(raw, dict):
            log.warning("allowlist: 'pending' is %s, not a map; ignoring it",
                        type(raw).__name__)
            return
        for key, value in raw.items():
            uid = _as_id(key)
            if uid is None:
                log.warning("allowlist: dropping pending entry with non-numeric id %r", key)
                continue
            if not isinstance(value, dict):
                log.warning("allowlist: pending entry %s is %s, not an object; "
                            "keeping the id with no label", uid, type(value).__name__)
                value = {}
            label = value.get("label")
            try:
                last = float(value.get("last_notified", 0))
            except (TypeError, ValueError):
                # One bad timestamp must not drop its neighbours: that re-prompts
                # the admin about senders they have already been told about.
                log.warning("allowlist: pending entry %s has a non-numeric "
                            "last_notified %r; it will prompt once more",
                            uid, value.get("last_notified"))
                last = 0.0
            pending[uid] = {"label": str(label) if label else uid, "last_notified": last}

    # -- writing -------------------------------------------------------------

    def _save(self) -> None:
        data = {
            "approved": self._approved,
            "denied": sorted(self._denied),
            "pending": self._pending,
        }
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2))
        tmp.replace(self._path)

    def _mutate(self, change: Callable[[], None]) -> None:
        """Apply a change and persist it, or put memory back and raise.

        The admin reads the bridge's reply, not the disk. A save that failed and
        was swallowed left the process believing an attacker was denied while
        the next restart let them back in (or the reverse for approve).
        """
        with self._lock:
            before = (
                dict(self._approved),
                set(self._denied),
                {key: dict(value) for key, value in self._pending.items()},
            )
            change()
            try:
                self._save()
            except OSError as exc:
                self._approved, self._denied, self._pending = before
                raise AllowlistError(f"could not save {self._path}: {exc}") from exc

    # -- the queue -----------------------------------------------------------

    def is_approved(self, user: int) -> bool:
        with self._lock:
            return str(user) in self._approved

    def approve(self, user: int, label: str = "") -> None:
        def change() -> None:
            key = str(user)
            label_ = label or self._pending.get(key, {}).get("label", "") or key
            self._approved[key] = label_
            self._pending.pop(key, None)
            self._denied.discard(key)

        self._mutate(change)

    def deny(self, user: int) -> None:
        """Silence a pending sender for good: drop with no further prompts."""
        def change() -> None:
            key = str(user)
            self._denied.add(key)
            self._pending.pop(key, None)

        self._mutate(change)

    def revoke(self, user: int) -> bool:
        removed = str(user) in self._approved

        def change() -> None:
            self._approved.pop(str(user), None)

        self._mutate(change)
        return removed

    def note_pending(self, user: int, label: str) -> bool:
        """Record an unknown sender; True if the admin should be notified now."""
        with self._lock:
            key = str(user)
            if key in self._approved or key in self._denied:
                return False
            now = time.time()
            entry = self._pending.get(key)
            if entry and now - entry["last_notified"] < PENDING_NOTIFY_INTERVAL:
                return False
            self._pending[key] = {"label": label, "last_notified": now}
            try:
                self._save()
            except OSError as exc:
                # Keep the in-memory record: it is what rate limits the prompt,
                # so a stranger still cannot flood the admin this run.
                log.error("could not persist pending sender %s (%s); the "
                          "24h rate limit holds only until restart", key, exc)
            return True

    def summary(self) -> str:
        with self._lock:
            lines = [f"approved ({len(self._approved)}):"]
            lines += [f"  {uid}  {label}" for uid, label in sorted(self._approved.items())]
            if self._pending:
                lines.append(f"pending ({len(self._pending)}):")
                lines += [f"  {uid}  {v['label']}" for uid, v in sorted(self._pending.items())]
            if self._denied:
                lines.append(f"denied: {', '.join(sorted(self._denied))}")
            return "\n".join(lines)
