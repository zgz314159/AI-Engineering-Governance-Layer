#!/usr/bin/env bash
# Linux compat entry for scripts/20-build-source-tools.ps1
# Same core logic: prepare the local Spec Kit uv env, build Architecture Guard,
# build RuleSync — all from the pinned upstream sources.
#
# Minimal fix vs. the .ps1 stage: Architecture Guard ships only pnpm-lock.yaml
# (no package-lock.json), so `npm ci` cannot work anywhere; it is installed with
# the pnpm version it declares (packageManager: pnpm@11.20.0). RuleSync's
# patchedDependencies lockfile also requires pnpm 11 (pnpm 10 reports
# ERR_PNPM_LOCKFILE_CONFIG_MISMATCH).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC_KIT="$ROOT/upstream/spec-kit"
AG="$ROOT/upstream/architecture-guard"
RULESYNC="$ROOT/upstream/rulesync"
export PATH="$HOME/.local/bin:$PATH"
# pnpm aborts removing an existing node_modules without a TTY; force non-interactive
# (CI) mode so the recovery bootstrap runs headless.
export CI="${CI:-true}"

echo "[Spec Kit] preparing local uv environment"
uv sync --project "$SPEC_KIT"
uv run --project "$SPEC_KIT" specify version

echo "[Architecture Guard] pnpm install + build + upstream tests"
( cd "$AG" && npx --yes pnpm@11.20.0 install --frozen-lockfile )
( cd "$AG" && npm run build )
( cd "$AG" && npm test )

echo "[RuleSync] pnpm install + build from downloaded source"
( cd "$RULESYNC" && npx --yes pnpm@11.20.0 install --frozen-lockfile )
( cd "$RULESYNC" && npx --yes pnpm@11.20.0 run build )
node "$RULESYNC/dist/cli/index.js" --version

echo "[OK] Source-first tooling ready."
echo "BUILD-TOOLS: PASS"
