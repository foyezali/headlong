"""Text conversion between the agent's markdown and Slack.

Deliberately minimal — common markdown the agent emits, nothing close to
full CommonMark. Fenced and inline code are left untouched.
"""

from __future__ import annotations

import re

MAX_MESSAGE_CHARS = 3900  # Slack hard limit is ~4000; leave headroom

_CODE_SPLIT_RE = re.compile(r"(```.*?```|`[^`\n]*`)", re.DOTALL)
_MENTION_RE = re.compile(r"<@[A-Z0-9]+>")


def _convert_prose(text: str) -> str:
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r"<\2|\1>", text)  # [t](u) -> <u|t>
    text = re.sub(r"\*\*(.+?)\*\*", r"*\1*", text)  # **bold** -> *bold*
    text = re.sub(r"^#{1,6}\s+(.+)$", r"*\1*", text, flags=re.MULTILINE)  # heading -> bold
    text = re.sub(r"^(\s*)[*+]\s+", r"\1- ", text, flags=re.MULTILINE)  # * item -> - item
    return text


def to_mrkdwn(text: str) -> str:
    """Convert agent markdown to Slack mrkdwn, skipping code spans."""
    parts = _CODE_SPLIT_RE.split(text)
    return "".join(p if p.startswith("`") else _convert_prose(p) for p in parts)


_LEAK_PREFIX_RE = re.compile(r"^\s*chat\s+reply\b")
_LEAK_TEXT_COMMAND_RE = re.compile(r"chat\s+reply\b")
_LEAK_TOKEN_RE = re.compile(r"\S+")
_LEAK_FLAGS = frozenset({"--follow-up", "--force"})
_LEAK_FLAGS_WITH_VALUE = frozenset({"--reply-to"})


def strip_leaked_command(text: str) -> str:
    """Drop a leading 'chat reply [flags] <name>' the model echoed into a reply.

    The guard only knew the bare two-token form, but the command an agent is
    told to use carries flags and a trigger step id before the target name
    (`chat reply --reply-to <step> <name> <message>`), so an echoed follow-up
    reached the person reading "--reply-to <step> <name> The fix is in."

    Flags are parsed as flags now, by character position so the body keeps its
    own line breaks. An unknown option abandons the strip rather than guessing
    how many words belong to it: a guard that half-eats a line invents text
    instead of hiding it. A command echoed with no message after it is left
    alone, because there is nothing to protect a person from.
    """
    if not _LEAK_PREFIX_RE.match(text):
        return text
    spans = [m.span() for m in _LEAK_TOKEN_RE.finditer(text)]
    tokens = [m.group(0) for m in _LEAK_TOKEN_RE.finditer(text)]
    if len(tokens) < 2 or tokens[0] != "chat" or tokens[1] != "reply":
        return text
    i = 2
    while i < len(tokens) and tokens[i].startswith("--"):
        if tokens[i] in _LEAK_FLAGS_WITH_VALUE:
            i += 2
        elif tokens[i] in _LEAK_FLAGS:
            i += 1
        else:
            return text
    i += 1  # the target name
    if i >= len(tokens):
        return text
    return text[spans[i][0]:]


def clean_inbound(text: str, bot_user_id: str | None = None) -> str:
    """Normalize a Slack message body for the mind log."""
    if bot_user_id:
        text = text.replace(f"<@{bot_user_id}>", "")
    text = _MENTION_RE.sub(lambda m: m.group(0)[2:-1], text)  # other mentions -> bare id
    text = re.sub(r"<(https?://[^|>]+)\|([^>]+)>", r"\2 (\1)", text)  # <url|label>
    text = re.sub(r"<(https?://[^>]+)>", r"\1", text)  # <url>
    text = text.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
    return text.strip()


def chunk(text: str, limit: int = MAX_MESSAGE_CHARS) -> list[str]:
    """Split long text at paragraph (then line, then hard) boundaries."""
    if len(text) <= limit:
        return [text]
    chunks: list[str] = []
    remaining = text
    while len(remaining) > limit:
        window = remaining[:limit]
        cut = window.rfind("\n\n")
        if cut < limit // 2:
            cut = window.rfind("\n")
        if cut < limit // 2:
            cut = limit
        chunks.append(remaining[:cut].rstrip("\n"))
        remaining = remaining[cut:].lstrip("\n")
    if remaining:
        chunks.append(remaining)
    return chunks
