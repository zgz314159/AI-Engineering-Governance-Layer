#!/usr/bin/env bash
# Linux compat entry for scripts/60-negative-test.ps1
# Same core logic:
#   1. inject Domain -> Presentation and prove Konsist blocks it;
#   2. inject a Detekt MagicNumber and prove Detekt blocks it;
#   3. restore the fixture and prove it is green again.
# Minimal fix vs. the .ps1 stage: uses the Linux `./gradlew` launcher.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/fixture"
REPORTS="$ROOT/reports"
mkdir -p "$REPORTS"

BAD_ARCH="$FIXTURE/src/main/kotlin/com/example/governed/domain/IllegalDependency.kt"
BAD_DETEKT="$FIXTURE/src/main/kotlin/com/example/governed/domain/MagicNumberViolation.kt"

cd "$FIXTURE"
chmod +x ./gradlew

ARCH_RESULT="FAIL"
DETEKT_RESULT="FAIL"
RESTORE_RESULT="FAIL"

cleanup_arch() { rm -f "$BAD_ARCH"; }
cleanup_detekt() { rm -f "$BAD_DETEKT"; }
trap 'cleanup_arch; cleanup_detekt' EXIT

# --- Negative test 1: architecture violation -------------------------------
cat > "$BAD_ARCH" <<'KOTLIN'
package com.example.governed.domain

import com.example.governed.presentation.GreetingService

class IllegalDependency(
    private val presentation: GreetingService
)
KOTLIN

echo "[NEGATIVE] Intentionally violating Domain -> Presentation"
set +e
ARCH_LOG="$(./gradlew test 2>&1)"
ARCH_CODE=$?
set -e
cleanup_arch

if [ "$ARCH_CODE" -eq 0 ]; then
    echo "NEGATIVE ARCHITECTURE TEST FAILED: Konsist allowed an illegal dependency." >&2
else
    if printf '%s' "$ARCH_LOG" | grep -qE 'KoAssertionFailedException|GeneratedArchitectureTest.*FAILED'; then
        ARCH_RESULT="PASS"
        echo "NEGATIVE ARCHITECTURE TEST: PASS (violation correctly blocked)"
    else
        echo "NEGATIVE ARCHITECTURE TEST: FAILED (build failed but no Konsist architecture signal)" >&2
        printf '%s\n' "$ARCH_LOG" | tail -30 >&2
    fi
fi

# --- Negative test 2: Detekt violation -------------------------------------
cat > "$BAD_DETEKT" <<'KOTLIN'
package com.example.governed.domain

fun forbiddenMagicNumber(): Int {
    val answer = 42
    return answer
}
KOTLIN

echo "[NEGATIVE] Intentionally creating Detekt MagicNumber violation"
set +e
DETEKT_LOG="$(./gradlew detekt 2>&1)"
DETEKT_CODE=$?
set -e
cleanup_detekt

if [ "$DETEKT_CODE" -eq 0 ]; then
    echo "NEGATIVE DETEKT TEST FAILED: Detekt allowed the configured violation." >&2
else
    if printf '%s' "$DETEKT_LOG" | grep -qE '\[MagicNumber\]'; then
        DETEKT_RESULT="PASS"
        echo "NEGATIVE DETEKT TEST: PASS (violation correctly blocked)"
    else
        echo "NEGATIVE DETEKT TEST: FAILED (build failed but no Detekt [MagicNumber] signal)" >&2
        printf '%s\n' "$DETEKT_LOG" | tail -30 >&2
    fi
fi

# --- Restore and prove green ------------------------------------------------
echo "[RESTORE] verifying the fixture returns to green"
set +e
./gradlew qualityGate
RESTORE_CODE=$?
set -e
if [ "$RESTORE_CODE" -eq 0 ]; then
    RESTORE_RESULT="PASS"
    echo "FIXTURE RESTORED: PASS"
else
    echo "ERROR: fixture did not return to green after negative tests." >&2
fi

python3 - "$REPORTS/negative-result.json" "$ARCH_RESULT" "$DETEKT_RESULT" "$RESTORE_RESULT" <<'PY'
import json, sys
path, arch, detekt, restore = sys.argv[1:5]
json.dump({
    "negativeArchitectureViolation": "BLOCKED_AS_EXPECTED" if arch == "PASS" else "NOT_BLOCKED",
    "negativeDetektViolation": "BLOCKED_AS_EXPECTED" if detekt == "PASS" else "NOT_BLOCKED",
    "fixtureRestored": restore,
}, open(path, "w"), indent=2)
PY

if [ "$ARCH_RESULT" != "PASS" ] || [ "$DETEKT_RESULT" != "PASS" ] || [ "$RESTORE_RESULT" != "PASS" ]; then
    echo "NEGATIVE TESTS: FAIL" >&2
    exit 1
fi
echo "NEGATIVE TESTS: PASS"
