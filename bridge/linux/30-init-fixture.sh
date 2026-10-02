#!/usr/bin/env bash
# Linux compat entry for scripts/30-init-fixture.ps1
# Same core logic: init the fixture with the local Spec Kit, then register the
# local Architecture Guard source as a Spec Kit dev extension.
#
# Minimal fix vs. the .ps1 stage: `--script ps` generates PowerShell helper
# scripts into the fixture; on Linux the sh variant is used instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/fixture"
SPEC_KIT="$ROOT/upstream/spec-kit"
AG="$ROOT/upstream/architecture-guard"
export PATH="$HOME/.local/bin:$PATH"

cd "$FIXTURE"

if [ ! -d "$FIXTURE/.specify" ]; then
    echo "[Spec Kit] initialize fixture from local downloaded source"
    uv run --project "$SPEC_KIT" specify init --here --force --non-interactive \
        --integration claude --script sh --ignore-agent-tools
else
    echo "[Spec Kit] fixture already initialized"
fi

echo "[Architecture Guard] install local downloaded source as Spec Kit dev extension"
# `--dev` is a boolean flag; the local directory is the positional argument.
uv run --project "$SPEC_KIT" specify extension add "$AG" --dev --force

echo "[Architecture Guard] verify registration"
# Spec Kit 1.0.6 `extension list` has no --json flag; the install registry is
# the authoritative machine-readable record.
REGISTRY="$FIXTURE/.specify/extensions/.registry"
if ! python3 - "$REGISTRY" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1]))
ok = "architecture-guard" in reg.get("extensions", {}) and \
     reg["extensions"]["architecture-guard"].get("enabled", False)
sys.exit(0 if ok else 1)
PY
then
    echo "ERROR: Architecture Guard extension is not registered/enabled in Spec Kit." >&2
    exit 1
fi
echo "[OK] Architecture Guard registered in .specify/extensions/.registry."

echo "[OK] Architecture Guard registered."
echo "INIT-FIXTURE: PASS"
