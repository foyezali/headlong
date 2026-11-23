"""Bridge configuration from environment variables.

All settings come from the process environment (in production the systemd
unit loads the box's .env via EnvironmentFile).
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    serve_root: Path
    identity: str
    identity_dir: Path
    bot_token: str
    app_token: str
    web_url: str
    state_dir: Path
    thread_followups: bool
    # How many messages above a first @mention to prepend. 0 disables.
    thread_join_backfill: int = 20
    # Peer hearing: bot user ids of other Headlong personas whose Slack
    # posts may reach this mind. Empty (the default) keeps the old rule
    # that every bot post is dropped. See design/peer_hearing.md.
    peer_bot_users: frozenset[str] = frozenset()
    # Loop guard: consecutive peer messages forwarded in one thread with no
    # person speaking in between, and total peer messages per hour.
    peer_max_turns: int = 4
    peer_hourly_cap: int = 30

    @property
    def identity_api_id(self) -> str:
        """Identity id for the web API: root-relative path with / -> ~."""
        rel = self.identity_dir.relative_to(self.serve_root)
        return str(rel).replace("/", "~")


def _default_identity(serve_root: Path) -> str:
    """The identity the `default` symlink points at, as `persona` resolves it.

    The immediate link target, not the end of the chain: an identity dir may
    itself be a symlink elsewhere, and its name here is the one `identity
    default` recorded.
    """
    for base in (".identities", "identities"):
        link = serve_root / base / "default"
        if link.is_symlink():
            name = link.readlink().name
            # A dangling default is its own error: passing the name on would
            # surface as "identity not found ... identity new <name>", advice
            # that creates a second identity instead of fixing the link.
            if not (serve_root / base / name).is_dir():
                raise SystemExit(
                    f"headlong-slack-bridge: the default identity link {link} "
                    f"points at '{name}', which is not an identity under "
                    f"{serve_root / base}. Repoint it with: identity default <name>"
                )
            return name
    raise SystemExit(
        "headlong-slack-bridge: no identity given and no default set "
        f"under {serve_root} (looked for .identities/default and "
        "identities/default). Set HEADLONG_SLACK_IDENTITY, or point the "
        "default at one with: identity default <name>"
    )


def _find_identity_dir(serve_root: Path, name: str) -> Path:
    for base in (".identities", "identities"):
        candidate = serve_root / base / name
        if (candidate / "info.txt").is_file():
            return candidate
    raise SystemExit(
        f"headlong-slack-bridge: identity '{name}' not found under {serve_root} "
        "(looked in .identities/ and identities/). Create it with: identity new "
        + name
    )


def load(serve_root: Path) -> Config:
    # SLACK_CLI_* fallbacks: `slack run` provides tokens under these names
    # when it drives the bridge as the project's start hook.
    bot_token = os.environ.get("SLACK_BOT_TOKEN") or os.environ.get("SLACK_CLI_XOXB", "")
    app_token = os.environ.get("SLACK_APP_TOKEN") or os.environ.get("SLACK_CLI_XAPP", "")
    if not bot_token or not app_token:
        raise SystemExit(
            "headlong-slack-bridge: SLACK_BOT_TOKEN and SLACK_APP_TOKEN are required"
        )
    # HEADLONG_* is canonical; SHELLM_* accepted as a legacy fallback until the
    # deployed boxes migrate their env files.
    identity = (
        os.environ.get("HEADLONG_SLACK_IDENTITY")
        or os.environ.get("SHELLM_SLACK_IDENTITY")
        or _default_identity(serve_root)
    )
    identity_dir = _find_identity_dir(serve_root, identity)
    state_dir = Path(
        os.environ.get("HEADLONG_SLACK_STATE_DIR")
        or os.environ.get("SHELLM_SLACK_STATE_DIR")
        or identity_dir / "run" / "slack-bridge"
    )
    state_dir.mkdir(parents=True, exist_ok=True)
    return Config(
        serve_root=serve_root,
        identity=identity,
        identity_dir=identity_dir,
        bot_token=bot_token,
        app_token=app_token,
        web_url=(
            os.environ.get("HEADLONG_WEB_URL")
            or os.environ.get("SHELLM_WEB_URL")
            or "http://127.0.0.1:8080"
        ).rstrip("/"),
        state_dir=state_dir,
        thread_followups=_bool_env("SLACK_THREAD_FOLLOWUPS"),
        thread_join_backfill=_join_backfill_limit(),
        peer_bot_users=_peer_bot_users(),
        peer_max_turns=_int_env("SLACK_PEER_MAX_TURNS", 4, 0, 50),
        peer_hourly_cap=_int_env("SLACK_PEER_HOURLY_CAP", 30, 0, 1000),
    )


def _peer_bot_users() -> frozenset[str]:
    """SLACK_PEER_BOT_USERS: bot user ids (U.../W...) of peers, any separator.

    Anything that is not a Slack user id is ignored, so a stray bot id
    (B...) or a display name cannot open the gate by accident.
    """
    raw = os.environ.get("SLACK_PEER_BOT_USERS", "")
    ids = set()
    # Commas, semicolons and whitespace (spaces, tabs, newlines) all separate
    # ids. Splitting on commas alone read "U0AAA U0BBB" as one token, which is
    # not a user id, so the whole variable parsed to the empty set: peer
    # hearing silently off, nothing said anywhere.
    parts = raw.replace(";", ",").replace(",", " ").split()
    rejected = []
    for part in parts:
        if part[0] in "UW" and part.isalnum() and part == part.upper():
            ids.add(part)
        else:
            rejected.append(part)
    # A configured-but-empty peer list is the outcome this variable must never
    # reach quietly: every bot post is dropped, so nothing arrives and nothing
    # says why. Name the tokens that were tossed so a lowercase id or a display
    # name is a message, not a mystery.
    if raw.strip() and not ids:
        _warn("SLACK_PEER_BOT_USERS", raw, "any Slack user id (U...)", "nobody")
    elif rejected:
        print(
            "headlong-slack-bridge: SLACK_PEER_BOT_USERS ignored "
            + ", ".join(repr(t) for t in rejected)
            + " (not Slack user ids)",
            file=sys.stderr,
        )
    return frozenset(ids)


_TRUTHY = frozenset({"1", "true", "yes", "on"})


def _warn(name: str, raw: str, what: str, used) -> None:
    """Say on stderr that a knob was not understood and what was used instead.

    Every unparsed setting goes through here. The alternative — a silent
    fallback — is how an operator ends up certain a setting is on when it is
    not, and this bridge's settings are the loop guards and the peer gate.
    """
    print(
        f"headlong-slack-bridge: {name}={raw!r} is not {what}; "
        f"treating it as {used}",
        file=sys.stderr,
    )


def _bool_env(name: str, default: bool = False) -> bool:
    """Read `name` as a boolean: 1/true/yes/on means on, 0/false/no/off off.

    The old rule was `value not in ("", "0")`, which reads every value that is
    not empty or a bare zero as ON. So `SLACK_THREAD_FOLLOWUPS=false` enabled
    follow-ups, and `=no`, `=off`, `= 0` and any typo did too. The bridge's
    docs only ever said to set `=1`, so nobody looked.

    An unrecognized value now falls back to `default` and says so on stderr,
    because quietly reading a typo as off is how an operator ends up with a
    setting they believe is on and is not. Unset or empty is a plain default.
    """
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    word = raw.strip().lower()
    if word in _TRUTHY:
        return True
    if word in ("0", "false", "no", "off"):
        return False
    _warn(name, raw, "a boolean (1/0, true/false, yes/no, on/off)", default)
    return default


def _int_env(name: str, default: int, lo: int, hi: int) -> int:
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        n = int(raw.strip())
    except ValueError:
        _warn(name, raw, "a whole number", default)
        return default
    clamped = max(lo, min(hi, n))
    if clamped != n:
        _warn(name, raw, f"between {lo} and {hi}", clamped)
    return clamped


def _join_backfill_limit() -> int:
    """SLACK_THREAD_JOIN_BACKFILL: prior thread lines on first @mention.

    Default 20. 0 disables. Clamped to 50 so a long thread cannot dump.
    Shares _int_env so a typo here is reported like every other knob.
    """
    return _int_env("SLACK_THREAD_JOIN_BACKFILL", 20, 0, 50)
