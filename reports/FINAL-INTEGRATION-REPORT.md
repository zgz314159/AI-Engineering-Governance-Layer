# AI Engineering Governance Layer — Final Integration Report

Generated: 2026-10-02T09:20:34.105780+00:00
Status: **PASS**

## Platform & Environment
- OS: Ubuntu 24.04.5 LTS (x86_64) (kernel 7.0.0-34-generic)
- git: git version 2.43.0
- node: v24.21.0
- npm: 11.19.0
- pnpm: 11.20.0 (npx, used to build Architecture Guard + RuleSync)
- java: openjdk version "21.0.12.1" 2026-08-18
- python: Python 3.12.3
- uv: uv 0.12.22 (x86_64-unknown-linux-gnu)
- PowerShell (pwsh): NOT INSTALLED
- Gradle: gradle-8.12.1
- Execution mode: Linux bridge (`bootstrap.sh` + `bridge/linux/*`), Windows entry `bootstrap.ps1` preserved.

## Canonical source
`governance/policy.json` -> constitution / architecture constitution / security constitution ->
Architecture Guard (Spec Kit adapter) / RuleSync rules / Konsist test -> Gradle qualityGate -> CI.

## Upstream pins (version + commit SHA + connection)
- **spec-kit**: v1.0.6 @ 96c9bd657bfd5de0d651a6165084932b7304ac99 (https://github.com/github/spec-kit.git)
- **architecture-guard**: v2.3.6 @ fe70fc7f02e3eef5173abf83f2f8ca5b4a11a1cc (https://github.com/DyanGalih/architecture-guard.git)
- **konsist**: v0.17.3 @ 8a31e2bbe4228547cc79b4c80ae5a0aa9ce4cefe (https://github.com/LemonAppDev/konsist.git)
- **detekt**: v1.23.8 @ 046263730eb5368cb344489ac36543294e8e87bd (https://github.com/detekt/detekt.git)
- **rulesync**: v25.0.0 @ 0c141ffcd5523963f6aa7f669a6671dbe04b0e4a (https://github.com/dyoshikawa/rulesync.git)
- **gradle-actions**: v6.1.0 @ 50e97c2cd7a37755bbfafc9c5b7cafaece252f6e (https://github.com/gradle/actions.git)

## Connections
- **specKit**: local submodule executed via `uv run --project upstream/spec-kit`
- **architectureGuard**: built from local submodule (pnpm), installed as Spec Kit dev extension via `specify extension add <path> --dev`
- **ruleSync**: built from local submodule (pnpm), executed as `node upstream/rulesync/dist/cli/index.js`
- **konsist**: fixture consumes published artifact com.lemonappdev:konsist:0.17.3 (mavenCentral); source submodule pinned for audit
- **detekt**: fixture consumes published Gradle plugin 1.23.8; source submodule pinned for audit
- **gradleActions**: CI uses local submodule action ./upstream/gradle-actions/setup-gradle

## Positive tests
- **specKitRuntime**: PASS
- **architectureGuardRegistration**: PASS
- **architectureGuardCommands**: PASS
- **rulesyncDriftCheck**: PASS
- **gradleQualityGate**: PASS

## Negative tests
- **negativeArchitectureViolation**: BLOCKED_AS_EXPECTED
- **negativeDetektViolation**: BLOCKED_AS_EXPECTED
- **fixtureRestored**: PASS

## Agent semantic smoke test (reported separately from deterministic gates)
- **status**: PASS (agent semantic check, separate from deterministic gates)
- **performedBy**: Command Code agent (interactive session on this fixture)
- **adapterResolution**: PASS - .specify/extensions/architecture-guard/adapters/{resolve.md,spec-kit.md} present; the skill's constitution paths (.specify/memory/architecture_constitution.md) match the rendered files
- **skillsInstalled**: PASS - Architecture Guard ag-* skills projected into fixture/.claude/skills (e.g. speckit-architecture-guard-ag-review-implementation)
- **constitutionsRead**: ['constitution.md', 'architecture_constitution.md', 'security_constitution.md']
- **semanticFinding**: Human/agent reading of governance/policy.json outputs: Domain imports nothing; Presentation and Data depend only on Domain. This is compliant. A Domain -> Presentation dependency is recognized as a blocking architecture violation (Domain is independent).
- **corroboration**: Agrees with the deterministic Konsist negative test (violation correctly blocked).
- **note**: A full interactive invocation of /ag-review-implementation via a Claude/Codex agent session is a manual step; here the semantic evaluation was executed directly by this agent against the rendered constitutions.

## Modified bootstrap/bridge/config files
- bootstrap.sh (NEW Linux compat entry; bootstrap.ps1 left unchanged as Windows entry)
- bridge/linux/00-check-prereqs.sh (NEW)
- bridge/linux/10-fetch-upstreams.sh (NEW; +HTTP/1.1 + shallow retry vs flaky TLS)
- bridge/linux/20-build-source-tools.sh (NEW; FIX: Architecture Guard installed with pnpm not npm ci)
- bridge/linux/30-init-fixture.sh (NEW; FIX: --script sh; extension add <path> --dev --force)
- bridge/linux/40-render-governance.sh (NEW; FIX: Konsist import KoArchitectureCreator.assertArchitecture)
- bridge/linux/45-bootstrap-gradle.sh (NEW; FIX: gradle launcher + gradlew instead of gradlew.bat)
- bridge/linux/50-positive-test.sh (NEW)
- bridge/linux/60-negative-test.sh (NEW; FIX: gradlew instead of gradlew.bat)
- bridge/linux/70-write-report.sh (NEW)
- fixture/rulesync.jsonc (generated)
- fixture/.specify/memory/{constitution,architecture_constitution,security_constitution}.md (generated)
- fixture/.rulesync/rules/00-governance.md (generated)
- fixture/src/test/kotlin/com/example/governed/architecture/GeneratedArchitectureTest.kt (generated)

## GitHub Actions
PENDING REMOTE VERIFICATION (workflow .github/workflows/governance-ci.yml present; not yet run on a remote)

## Open issues
- GitHub Actions workflow (.github/workflows/governance-ci.yml) is PENDING REMOTE VERIFICATION; it runs the fixture `./gradlew qualityGate` and is executed after push to GitHub.
- AGENT SEMANTIC SMOKE TEST was performed by the agent (see reports/agent-smoke-result.json); a full interactive /ag-review-implementation run via a Claude/Codex agent session remains a manual step (docs/AGENT-SMOKE-TEST.md).
- PowerShell 7 not installed on this host, so the Windows entry (bootstrap.ps1) could not be executed here; the Linux bridge mirrors its stages.
- RuleSync's own `prepare` lifecycle writes projections into the rulesync source tree during install (upstream behavior, harmless to the fixture).

## Final result
**PASS**
