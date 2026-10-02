# AEGL persistent-memory fixtures (v1.4)

Test fixtures for the OPTIONAL Beads persistent-memory backend
(`core/continuity/backends/beads.py`).

- `fake-bin/bd` — a minimal deterministic **stub** for the `bd` CLI used by
  `scripts/memory-smoke.py` to exercise the runner, version parsing, JSON
  parsing, timeout handling and error mapping hermetically (no network, no real
  Beads).

It is deliberately **not** a Beads reimplementation and is **not** a substitute
for the real integration test. The real integration test runs against the
checksum-pinned Beads release (see `versions.json["beads"]`) via
`scripts/memory-smoke.py --bd /path/to/bd`.

The stub's behaviour is switched with environment variables:

| Variable | Values | Effect |
|----------|--------|--------|
| `FAKE_BD_MODE` | `normal` (default), `timeout`, `fail`, `invalid-json` | Failure-mode injection |
| `FAKE_BD_VERSION` | e.g. `2.0.0` | Version reported by `bd --version` |

The backend is pointed at a specific binary with `AEGL_BEADS_BIN=<path>` — a
nonexistent path simulates a missing `bd` deterministically, with no `PATH`
manipulation.
