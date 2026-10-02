# Project Constitution

Project: Governance Fixture
Policy version: 1.0.0

## Engineering Principles
- Specifications and architecture rules are authoritative before implementation.
- AI agents MUST NOT silently change architecture to make implementation easier.
- A task is complete only after deterministic quality gates pass.
- Generated AI rules are outputs; edit governance/policy.json instead.

## Definition of Done
- RuleSync generated files are current
- Konsist architecture tests pass
- Detekt reports zero issues
- JUnit tests pass
- Gradle qualityGate passes

## Governance Rule
AI agents MUST NOT declare work complete unless the deterministic `qualityGate` passes.
Architecture changes MUST be explicit; they MUST NOT be introduced silently during implementation.

> GENERATED from `governance/policy.json`. Do not edit directly.
