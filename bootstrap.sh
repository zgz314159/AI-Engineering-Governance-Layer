#!/usr/bin/env bash
# Linux compatibility entry for bootstrap.ps1.
#
# Same core logic and same canonical governance source (governance/policy.json)
# as bootstrap.ps1. The *.ps1 stages are kept as the Windows/PowerShell entry;
# these stages are the minimal Linux bridge required because the .ps1 stages use
# Windows-only implementations (winget, gradlew.bat, `--script ps`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$ROOT/bridge/linux"
export PATH="$HOME/.local/bin:$PATH"

step() {
    echo ""
    echo "================================================================"
    echo "$1"
    echo "================================================================"
}

step "0/7 Prerequisite check"
bash "$BRIDGE/00-check-prereqs.sh"

step "1/7 Fetch and pin upstream source projects"
bash "$BRIDGE/10-fetch-upstreams.sh"

step "2/7 Build source-first tooling"
bash "$BRIDGE/20-build-source-tools.sh"

step "3/7 Initialize Spec Kit + Architecture Guard fixture"
bash "$BRIDGE/30-init-fixture.sh"

step "4/7 Render policy -> Spec Kit / RuleSync / Konsist"
bash "$BRIDGE/40-render-governance.sh"

step "5/7 Bootstrap Gradle wrapper"
bash "$BRIDGE/45-bootstrap-gradle.sh"

step "6/7 Run positive and negative integration tests"
bash "$BRIDGE/50-positive-test.sh"
bash "$BRIDGE/60-negative-test.sh"

step "7/7 Write integration report"
bash "$BRIDGE/70-write-report.sh"

echo ""
echo "==============================================================="
echo "GOVERNANCE LAYER: PASS"
echo "Report: $ROOT/reports/bootstrap-report.json"
echo "==============================================================="
