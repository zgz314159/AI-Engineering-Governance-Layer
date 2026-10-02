#!/usr/bin/env bash
# Linux compat entry for scripts/00-check-prereqs.ps1
# Same core logic: verify git/node>=22/npm/java/python/uv. Installs uv via the
# official astral installer instead of winget (Windows-only).
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

have() { command -v "$1" >/dev/null 2>&1; }

require() {
    local name="$1" hint="$2"
    if ! have "$name"; then
        echo "ERROR: missing required command '$name'. $hint" >&2
        exit 1
    fi
    echo "[OK] $name -> $(command -v "$name")"
}

require git "Install Git."
require node "Install Node.js 22+."
require npm "npm must accompany Node.js."
require java "Install JDK 21."
if have python; then
    PY=python
elif have python3; then
    PY=python3
else
    echo "ERROR: python not found. Install Python 3.11+." >&2
    exit 1
fi
require "$PY" "Install Python 3.11+."

if ! have uv; then
    echo "[INFO] uv not found; installing with the astral installer..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
require uv "Spec Kit requires uv."

NODE_MAJOR="$(node --version | sed 's/^v//' | cut -d. -f1)"
if [ "$NODE_MAJOR" -lt 22 ]; then
    echo "ERROR: Node.js 22+ required for RuleSync source build. Current: $(node --version)" >&2
    exit 1
fi

PY_VERSION="$("$PY" --version 2>&1 | awk '{print $2}')"
PY_MAJOR="$(echo "$PY_VERSION" | cut -d. -f1)"
PY_MINOR="$(echo "$PY_VERSION" | cut -d. -f2)"
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 11 ]; }; then
    echo "ERROR: Python 3.11+ required. Current: $PY_VERSION" >&2
    exit 1
fi

echo "[OK] Node $(node --version)"
echo "[OK] Python $PY_VERSION"
echo "[OK] Java:"
java -version
echo "[OK] uv $(uv --version)"
echo "PREREQS: PASS"
