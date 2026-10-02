"""Best-effort secret and path redaction for the Continuity handoff.

This stops obvious credentials from being persisted into ``state.json`` /
``HANDOFF.md`` / ``NEXT-SESSION.md`` / ``events.jsonl``. It is intentionally
NOT a DLP platform (build plan §35) and makes no attempt at semantic
correctness — it only scrubs well-known credential shapes and normalises
non-essential absolute home paths (§36).
"""
from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

REDACTED = "[REDACTED]"

# Credential-ish NAME=value / NAME: value. Matching on the *name* so the key is
# preserved and only the value is replaced. Requires an explicit credential
# suffix (``_TOKEN``, ``_KEY`` ...) or a whole-word credential name, so ordinary
# words such as "monkey" or "author" are never touched.
_KEY_VALUE = re.compile(
    r"""(?ix)
    \b(
        [A-Za-z0-9_.\-]*(?:_KEY|_TOKEN|_SECRET|_PASSWORD|_PASSWD|_CREDENTIALS)
        | API_?KEY | ACCESS_KEY | SECRET_KEY
        | TOKEN | SECRET | PASSWORD | PASSWD
    )\b
    (\s*[:=]\s*)
    ("[^"]*" | '[^']*' | \S+)
    """
)

# Authorization: <scheme?> <credential>  — redacts only the credential so the
# rest of the line survives.
_AUTH_HEADER = re.compile(
    r"(?i)\b(authorization\s*:\s*)(?:bearer|basic|token)?\s*([A-Za-z0-9._~+/=\-]{6,})"
)
_BEARER = re.compile(r"(?i)\b(bearer)\s+([A-Za-z0-9._~+/=\-]{6,})")

# Well-known provider token shapes.
_PROVIDER_TOKENS = re.compile(
    r"""(?x)
    \b(
        gh[pousr]_[A-Za-z0-9]{20,}
        | github_pat_[A-Za-z0-9_]{20,}
        | sk-[A-Za-z0-9]{16,}
        | AKIA[0-9A-Z]{16}
        | xox[baprs]-[A-Za-z0-9-]{10,}
    )\b
    """
)

_PRIVATE_KEY = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
    re.DOTALL,
)


def redact_text(text: str) -> str:
    """Return ``text`` with recognised credential values replaced by [REDACTED]."""
    if not isinstance(text, str) or not text:
        return text
    out = _PRIVATE_KEY.sub(REDACTED, text)
    out = _PROVIDER_TOKENS.sub(REDACTED, out)
    out = _AUTH_HEADER.sub(lambda m: f"{m.group(1)}{REDACTED}", out)
    out = _BEARER.sub(lambda m: f"{m.group(1)} {REDACTED}", out)
    out = _KEY_VALUE.sub(lambda m: f"{m.group(1)}{m.group(2)}{REDACTED}", out)
    return out


def _home() -> str:
    return str(Path.home())


def normalize_paths_text(text: str, home: str | None = None) -> str:
    """Normalise non-essential absolute home paths to ``$HOME/...`` (§36)."""
    if not isinstance(text, str) or not text:
        return text
    home = home or _home()
    if not home or home == os.sep:
        return text
    out = text.replace(home, "$HOME")
    alt = home.replace("/", "\\")
    if alt != home:
        out = out.replace(alt, "$HOME")
    return out


def clean_text(text: str) -> str:
    """Redact secrets, then normalise home paths."""
    return normalize_paths_text(redact_text(text))


def clean_obj(value: Any) -> Any:
    """Recursively apply :func:`clean_text` to every string in a JSON value."""
    if isinstance(value, str):
        return clean_text(value)
    if isinstance(value, list):
        return [clean_obj(v) for v in value]
    if isinstance(value, dict):
        return {k: clean_obj(v) for k, v in value.items()}
    return value
