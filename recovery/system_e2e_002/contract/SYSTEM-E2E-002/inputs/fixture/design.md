# Implementation Design — Fixture Feature

## Architecture
The fixture reuses the existing `app/Main.kt` surface. Nothing is rebuilt.

## Data Flow
Control tap -> in-memory state -> rendered control.

## File Structure Plan

**MUST TOUCH**
| File | Role | Expected change |
| --- | --- | --- |
| `app/Main.kt` | entry surface | add the example-action control |

**MAY TOUCH**
| File | Role | Expected change |
| --- | --- | --- |
| `app/Main.kt` | entry surface | none |

**MUST NOT TOUCH**
- `app/Frozen.kt` — frozen example.

## Selector Contract
`fixture-action` -> `Modifier.testTag("fixture-action")` -> `By.res("fixture-action")`.

## Contract Metadata
```json
{
  "decisions": [
    { "id": "DEC-001", "statement": "Reuse the existing surface.", "rationale": "It already renders the list." }
  ],
  "assumptions": [
    { "id": "ASM-001", "statement": "The surface stays single-screen." }
  ],
  "data_change": {
    "schema_version_current": 2,
    "schema_version_target": 2,
    "migration_required": false,
    "notes": "No schema change; the field already exists."
  },
  "ui_change": {
    "surfaces": ["fixture-surface"],
    "selectors_added": ["fixture-action"]
  },
  "selector_contract": [
    {
      "name": "fixture-action",
      "compose_test_tag": "fixture-action",
      "uiautomator": "By.res(\"fixture-action\")",
      "state": "default",
      "required": true
    }
  ],
  "stop_conditions": ["A required file is missing.", "A frozen decision is contradicted."]
}
```
