#!/usr/bin/env bash
# Linux compat entry for scripts/50-positive-test.sh (aka 50-positive-test.ps1)
# Same core logic: prove Spec Kit + Architecture Guard + RuleSync + the
# deterministic Gradle gate (Konsist + Detekt + JUnit) all pass on the healthy
# fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/fixture"
SPEC_KIT="$ROOT/upstream/spec-kit"
RULESYNC_CLI="$ROOT/upstream/rulesync/dist/cli/index.js"
export PATH="$HOME/.local/bin:$PATH"

cd "$FIXTURE"

# Generated reports resolve outside the project tree (XDG data). Override with AEGL_REPORTS_DIR.
AEGL_DATA_HOME="${AEGL_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/aegl"
REPORTS="${AEGL_REPORTS_DIR:-$AEGL_DATA_HOME/reports}"
mkdir -p "$REPORTS"

echo "[1] Spec Kit runtime"
uv run --project "$SPEC_KIT" specify version >/dev/null
echo "  Spec Kit: PASS"

echo "[2] Architecture Guard extension registration"
python3 - "$FIXTURE/.specify/extensions/.registry" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1]))
e = reg.get("extensions", {}).get("architecture-guard")
if not e or not e.get("enabled"):
    raise SystemExit("architecture-guard extension missing/disabled")
print("  Architecture Guard registration: PASS")
PY

echo "[3] Architecture Guard generated command/skill presence"
AG_COUNT="$(find "$FIXTURE" -type f \( -path '*architecture-guard*' -o -name 'ag-*' \) -not -path '*/node_modules/*' | wc -l)"
if [ "$AG_COUNT" -eq 0 ]; then
    echo "ERROR: no Architecture Guard agent command/skill files found." >&2
    exit 1
fi
echo "  Architecture Guard command/skill files: $AG_COUNT -> PASS"

echo "[4] RuleSync drift check"
node "$RULESYNC_CLI" generate --targets claudecode --features rules --check
node "$RULESYNC_CLI" generate --targets codexcli --features rules --check
node "$RULESYNC_CLI" generate --targets cursor --features rules --check
echo "  RuleSync drift check: PASS"

echo "[5] Gradle deterministic quality gate (Konsist + Detekt + JUnit)"
chmod +x ./gradlew
./gradlew clean qualityGate

if [ $? -ne 0 ]; then
    echo "ERROR: Gradle qualityGate failed." >&2
    exit 1
fi

python3 - "$REPORTS/positive-result.json" <<'PY'
import json, sys
json.dump({
    "specKitRuntime": "PASS",
    "architectureGuardRegistration": "PASS",
    "architectureGuardCommands": "PASS",
    "rulesyncDriftCheck": "PASS",
    "gradleQualityGate": "PASS",
}, open(sys.argv[1], "w"), indent=2)
PY

echo "POSITIVE GATE: PASS"
