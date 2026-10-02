# AI Engineering Governance

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


# Architecture Constitution

## Layer Boundaries
- **Presentation** (`com.example.governed.presentation..`) may depend on: **Domain**.
- **Data** (`com.example.governed.data..`) may depend on: **Domain**.
- **Domain** (`com.example.governed.domain..`) may depend on: **nothing**.

## Blocking Violations
- A layer depending on a layer not listed above is a blocking violation.
- Domain is independent and MUST NOT depend on presentation or data.
- AI agents MUST NOT weaken these boundaries merely to make an implementation easier.

## Evolution Policy
To change a layer boundary, update `governance/policy.json`, regenerate governance outputs, and make the policy change visible in review.

> GENERATED from `governance/policy.json`. Do not edit directly.


# Persistent Work Memory (optional)

AEGL can use Beads (bd) as an OPTIONAL long-horizon work graph and persistent
memory backend. AEGL owns session continuity; Beads owns the work graph;
RuleSync owns agent rules. When persistent work memory is enabled:
- aegl memory status   - check backend availability
- aegl memory ready    - long-horizon ready work (from bd ready)
- aegl bd ...          - task lifecycle (create / dep / update --claim / close / show)
- aegl memory remember - durable project knowledge only; secrets are rejected
- aegl handoff         - session continuity
Never run bd setup: it writes AGENTS.md / CLAUDE.md and would collide with RuleSync.
