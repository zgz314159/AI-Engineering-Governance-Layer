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
