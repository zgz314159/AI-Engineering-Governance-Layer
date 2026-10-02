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
| `kotlin`    | yes         | Gradle + Kotlin: detekt + Konsist architecture test    |
| `android`   | descriptor  | Android/Gradle — not implemented in v1.1               |
| `java`      | descriptor  | Java/Gradle or Maven — not implemented in v1.1         |
| `python`    | descriptor  | — not implemented in v1.1                              |
| `typescript`| descriptor  | — not implemented in v1.1                              |

Descriptor-only adapters are honest placeholders: `aegl` reports them as
`implemented: false` and refuses to `attach`/`verify` rather than pretending to
support them.

Non-implemented technologies are **not** claimed as supported anywhere.
