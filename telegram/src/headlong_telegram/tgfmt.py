"""Text conversion between the agent's markdown and Telegram.

Outbound targets Telegram's HTML parse mode (MarkdownV2's escaping rules
are a minefield). Deliberately minimal — common markdown the agent emits,
nothing close to full CommonMark.
"""

from __future__ import annotations

import html
import re

MAX_MESSAGE_CHARS = 3900  # Telegram hard limit is 4096; leave headroom
MAX_INBOUND_CHARS = 4000  # cap what one message can inject into the mind log

_CODE_SPLIT_RE = re.compile(r"(```.*?```|`[^`\n]*`)", re.DOTALL)


def _convert_prose(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"^#{1,6}\s+(.+)$", r"<b>\1</b>", text, flags=re.MULTILINE)
    text = re.sub(r"^(\s*)[*+]\s+", r"\1- ", text, flags=re.MULTILINE)
    return text


def _convert_code(span: str) -> str:
    if span.startswith("```"):
        body = span[3:-3]
        body = body.split("\n", 1)[1] if "\n" in body else body  # drop language tag
        return f"<pre>{html.escape(body, quote=False)}</pre>"
    return f"<code>{html.escape(span[1:-1], quote=False)}</code>"


def to_html(text: str) -> str:
    """Convert agent markdown to Telegram HTML, code spans preserved."""
    parts = _CODE_SPLIT_RE.split(text)
    return "".join(
        _convert_code(p) if p.startswith("`") else _convert_prose(p) for p in parts
    )


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


def clean_inbound(text: str) -> str:
    """Normalize a Telegram message body for the mind log."""
    text = text.strip()
    if len(text) > MAX_INBOUND_CHARS:
        text = text[:MAX_INBOUND_CHARS] + " …(truncated by bridge)"
    return text


def sender_label(user: dict) -> str:
    """One-line display label for a Telegram user object.

    The parts are attacker-controlled strings headed for the admin's
    approval prompt and the mind-log header — collapse whitespace and cap
    the length so a hostile display name can't spread across lines.
    """
    name = " ".join(
        p for p in (user.get("first_name", ""), user.get("last_name", "")) if p
    )
    if user.get("username"):
        name = f"{name} (@{user['username']})" if name else f"@{user['username']}"
    name = re.sub(r"\s+", " ", name).strip()
    return name[:64] or str(user.get("id", "?"))


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
