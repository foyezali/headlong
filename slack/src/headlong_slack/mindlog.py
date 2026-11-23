"""Follow an identity's root trajectory file (the mind log).

The trajectory is append-only JSONL; the bridge keeps a persisted byte
offset so restarts neither replay old steps nor miss new ones. Only
complete (newline-terminated) lines are consumed.
"""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path
from typing import Any, Callable, Iterator


def find_trajectory(identity_dir: Path) -> Path:
    """Locate the mind log, mirroring headlong_web.discovery.find_root_traj_dir."""
    info = {}
    info_txt = identity_dir / "info.txt"
    if info_txt.is_file():
        for line in info_txt.read_text().splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                info[key.strip()] = value.strip()
    traj_root = identity_dir / "trajectories"
    root_id = info.get("root_trajectory", "")
    if root_id:
        for match in sorted(traj_root.glob(f"{root_id[:8]}-*")):
            if (match / "trajectory.jsonl").is_file():
                return match / "trajectory.jsonl"
    if traj_root.is_dir():
        for candidate in sorted(traj_root.iterdir()):
            if (candidate / "trajectory.jsonl").is_file():
                return candidate / "trajectory.jsonl"
    raise SystemExit(f"headlong-slack-bridge: no trajectory.jsonl under {traj_root}")


def read_new(path: Path, offset: int) -> tuple[list[dict[str, Any]], int]:
    """Read complete JSONL lines appended since offset.

    Returns (steps, new_offset). Corrupt lines are skipped. If the file
    shrank (rebuilt/truncated) reading resumes at its END: a bridge that
    replays a rebuilt log re-sends every old message to real people, which
    is never what anyone wants (2026-09-09: 130 historical Telegram
    messages re-sent after an identity switch handed the bridge a stale
    offset).
    """
    size = path.stat().st_size
    if size < offset:
        return [], size
    if size == offset:
        return [], offset
    with path.open("rb") as f:
        f.seek(offset)
        buf = f.read(size - offset)
    last_newline = buf.rfind(b"\n")
    if last_newline < 0:
        return [], offset
    steps: list[dict[str, Any]] = []
    for line in buf[: last_newline + 1].splitlines():
        try:
            step = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(step, dict):
            steps.append(step)
    return steps, offset + last_newline + 1


def follow(
    path: Path,
    cursor_file: Path,
    poll_interval: float = 0.4,
    should_stop: Callable[[], bool] = lambda: False,
) -> Iterator[dict[str, Any]]:
    """Yield steps appended to the trajectory, starting at EOF (no replay).

    The cursor file holds "<offset> <trajectory path>". A cursor written for
    a different trajectory (the bridge was pointed at another identity, or
    the state dir is shared) is ignored and reading starts at EOF; an old
    offset-only cursor is honoured only if it does not exceed the file.
    """
    offset = _load_cursor(cursor_file, path)
    while not should_stop():
        steps, new_offset = read_new(path, offset)
        if new_offset != offset:
            offset = new_offset
            cursor_file.parent.mkdir(parents=True, exist_ok=True)
            cursor_file.write_text(_cursor_text(offset, path))
        yield from steps
        time.sleep(poll_interval)

# Bytes hashed to fingerprint where a file ended; see _sig. Enough to catch an
# in-place rewrite (compaction, an import, a restored backup) without reading a
# whole log on every poll.
SIG_BYTES = 512


def _sig(path: Path, offset: int) -> dict:
    """Where the log stood when it was read up to ``offset``: device, inode and
    the hash of the bytes ending at the offset. An appended log keeps all
    three; a rotated one (new inode) or one rewritten in place (different bytes
    before the offset) does not."""
    sig: dict = {"dev": None, "ino": None, "tail": None}
    try:
        st = path.stat()
    except OSError:
        return sig
    sig["dev"], sig["ino"] = st.st_dev, st.st_ino
    want = min(int(offset or 0), SIG_BYTES)
    if want > 0:
        try:
            with path.open("rb") as fh:
                fh.seek(int(offset) - want)
                sig["tail"] = hashlib.sha256(fh.read(want)).hexdigest()
        except OSError:
            pass
    return sig


def _sig_matches(prev, cur: dict) -> bool:
    if not isinstance(prev, dict):
        return False
    if any(prev.get(k) is None for k in ("dev", "ino", "tail")):
        return False
    return all(prev.get(k) == cur.get(k) for k in ("dev", "ino", "tail"))


def _cursor_text(offset: int, path: Path) -> str:
    sig = _sig(path, offset)
    return (
        f"{offset} {path.resolve()} "
        f"{sig['dev']} {sig['ino']} {sig['tail']}"
    )


def _load_cursor(cursor_file: Path, path: Path) -> int:
    """Resume point for ``path``, or its size when the cursor cannot be trusted.

    A cursor holds "<offset> <trajectory path> <dev> <ino> <tail-hash>". A
    cursor written for a different trajectory is ignored, as is one whose
    recorded signature no longer matches the bytes before its offset: a log
    rewritten in place and coming out LONGER used to keep its offset and resume
    mid-row, so old messages were both re-sent and lost. An old offset-only
    cursor carries no signature and is honoured if it does not exceed the file.
    """
    size = path.stat().st_size
    if not cursor_file.is_file():
        return size
    try:
        raw = cursor_file.read_text().strip()
    except OSError:
        return size
    parts = raw.split()
    if not parts or not parts[0].isdigit():
        return size
    offset = int(parts[0])
    if len(parts) >= 2 and parts[1] != str(path.resolve()):
        return size  # another trajectory's cursor: never replay this one
    if offset > size:
        return size
    if offset > 0 and not _at_row_boundary(path, offset):
        return size  # mid-row: the log was rewritten under this cursor
    if len(parts) >= 5:
        prev = {"dev": _maybe_int(parts[2]), "ino": _maybe_int(parts[3]), "tail": parts[4]}
        if not _sig_matches(prev, _sig(path, offset)):
            return size  # rewritten in place: never replay, never resume mid-row
    return offset


def _at_row_boundary(path: Path, offset: int) -> bool:
    """True when the byte just before ``offset`` ends a line, i.e. the offset a
    writer left us still falls between two rows of the file as it is now."""
    try:
        with path.open("rb") as fh:
            fh.seek(offset - 1)
            return fh.read(1) == b"\n"
    except OSError:
        return False


def _maybe_int(value: str):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
