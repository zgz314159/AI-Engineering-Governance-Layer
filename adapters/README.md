# AEGL adapters

AEGL (AI Engineering Governance Layer) separates a technology-agnostic **core**
(`core/`, `bin/aegl`) from per-technology **adapters** (`adapters/<language>/`).

Each adapter directory contains:

- `adapter.json` — a descriptor (language, build system, detection markers,
  capability flags, whether it is implemented).
- `adapter.py` — the implementation, loaded by the core only when
  `"implemented": true`.

## Status

| Adapter     | Implemented | Notes                                                  |
|-------------|-------------|--------------------------------------------------------|
| `android`   | yes         | Android/Gradle: multi-module Konsist + Detekt + Android Lint |
| `kotlin`    | yes         | Gradle + Kotlin: detekt + Konsist architecture test    |
| `java`      | descriptor  | Java/Gradle or Maven — not implemented                  |
| `python`    | descriptor  | — not implemented                                       |
| `typescript`| descriptor  | — not implemented                                       |

Descriptor-only adapters are honest placeholders: `aegl` reports them as
`implemented: false` and refuses to `attach`/`verify` rather than pretending to
support them.

Non-implemented technologies are **not** claimed as supported anywhere.
