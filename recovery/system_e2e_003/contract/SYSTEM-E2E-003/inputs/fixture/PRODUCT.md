# PRODUCT — Fixture Feature

## Product
A tiny fixture product used to self-test the Specification Compiler. It has no real users.

## Change Request
Add an `example-action` affordance to the fixture surface.

## Scope
- Add the `example-action` control.

## Non-Goals
- No schema change.
- No new dependency.

## Contract Metadata
```json
{
  "experiment": {
    "experiment_id": "FIXTURE-B1",
    "experiment_type": "SPEC_FIRST_BROWNFIELD",
    "matched_control_available": false,
    "contract_id": "FIXTURE-B1-CONTRACT",
    "mode": "brownfield"
  },
  "feature": {
    "feature_id": "FIXTURE",
    "title": "Fixture Feature",
    "summary": "A minimal package that must validate to READY."
  },
  "scope": ["Add the example-action control."],
  "non_goals": ["No schema change.", "No new dependency."],
  "unresolved_questions": []
}
```
