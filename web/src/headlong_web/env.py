"""Framework env vars: HEADLONG_* is canonical, SHELLM_* accepted as fallback.

Framework-level knobs read through here because the deployed box's parked
shellm-named machinery (/opt/shellm, the root .env, operator drop-ins) still
exports SHELLM_* names; the fallback retires when those paths are renamed.
Tool-level vars (SHELLM_MODEL and friends, read by bin/shellm and bin/llm)
are NOT routed through this helper — shellm is the RLM tool's own name and
its vars keep the SHELLM_ prefix on purpose.
"""

import os
import sys

__all__ = ["getenv", "getbool"]

_TRUTHY = frozenset({"1", "true", "yes", "on"})


def getenv(name: str, default: str | None = None) -> str | None:
    """Read env var `name` (a HEADLONG_* name); fall back to its SHELLM_* twin.

    An empty-but-set HEADLONG_* value wins over the SHELLM_* fallback, matching
    plain os.environ.get semantics for each name in turn.
    """
    if name in os.environ:
        return os.environ[name]
    legacy = name.replace("HEADLONG_", "SHELLM_", 1)
    if legacy != name and legacy in os.environ:
        return os.environ[legacy]
    return default


def getbool(name: str, default: bool = False) -> bool:
    """Read `name` (with the SHELLM_* fallback) as a boolean.

    On means one of 1/true/yes/on in any case; off means 0/false/no/off. An
    unrecognized value falls back to `default` AND says so on stderr, because
    the alternative — quietly reading a typo as off — is how an operator ends
    up with a setting they believe is on and is not. An unset or empty value
    is a plain default with no complaint.
    """
    raw = getenv(name)
    if raw is None or raw.strip() == "":
        return default
    word = raw.strip().lower()
    if word in _TRUTHY:
        return True
    if word in ("0", "false", "no", "off"):
        return False
    print(
        f"headlong-web: {name}={raw!r} is not a boolean (use 1/0, true/false, "
        f"yes/no, on/off); treating it as {default}",
        file=sys.stderr,
    )
    return default
