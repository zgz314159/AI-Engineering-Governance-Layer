# AEGL v1.4 — Beads Integration Analysis

Status: **Research + architecture decision baseline. No implementation.**
Scope: decide whether and how AEGL should integrate [Beads](https://github.com/gastownhall/beads) as a
persistent work-memory backend for **AEGL v1.4 Persistent Work Memory**.
Baseline AEGL state: **v1.3.0** (`main` @ `6f495c4`, released, CI green).
Upstream studied: **Beads v1.3.1** (`c1c4b642ac1c08d8c828007a1c2f96e47e43ef7c`, released 2026-09-30).

This document is written to be the施工基线 (construction baseline) for v1.4. It does
**not** change `VERSION`, `core/`, `adapters/`, `bin/aegl`, workflows, or governance. It
adds only this report and raw evidence under `docs/research/`.

---

## Provenance legend

Every load-bearing claim is tagged:

| Tag | Meaning |
|-----|---------|
| `[OFFICIAL]` | Beads official release / README / docs site / release metadata. |
| `[SOURCE]` | Read directly from Beads v1.3.1 source or embedded schema at commit `c1c4b642`. |
| `[SANDBOX]` | Reproduced on this host with the pinned v1.3.1 binary; see `docs/research/evidence/beads-v1.3.1-sandbox-evidence.md`. |
| `[COMMUNITY]` | Beads GitHub issues / discussions / community reports; a signal, not proof. |
| `[INFERRED]` | AEGL architecture inference made by this analysis. |

AEGL facts are `[SOURCE]` against the local AEGL repo at v1.3.0.

---

## Executive Summary

Beads v1.3.1 is a mature, actively developed, MIT-licensed CLI issue tracker ("a
memory upgrade for your coding agent") that stores a dependency-aware work graph in an
**embedded Dolt database**, ships a **static workflow-context injector (`bd prime`)**, a
**key→value persistent-memory** store (`bd remember`), **atomic task claiming**, and a
**Dolt/git cross-machine sync path**. Its storage engine is Dolt (versioned SQL); git is
**optional**. It is designed to be installed once, system-wide, and used from many
projects. `[OFFICIAL]`

AEGL v1.3 already owns **hot/warm session continuity** — `aegl status|handoff|resume`,
`state.json`, `HANDOFF.md`, `NEXT-SESSION.md`, the event log and history — and it already
reserves a `PersistentMemoryBackend` seam (`core/continuity/memory.py`) whose only
implementation is `none` and whose v1.4 target is explicitly documented as `beads`. `[SOURCE]`

The two systems are **complementary, not overlapping** `[SANDBOX]`:

- `aegl resume` answers *"is this checkout the one the last session handed off, and what
  was the goal / next command?"* — repository facts + session semantics.
- `bd prime` answers *"how do I use bd, and what project facts must I never forget?"* — a
  static workflow cheat-sheet plus the persistent-memory list. It **does not** query or
  print the work graph.
- `bd ready` answers *"what long-horizon work is actionable now?"* — the dependency DAG.

**Recommendation: Option B — integrate Beads as an OPTIONAL persistent-memory / work-graph
backend, driven through the `bd` CLI, never mandatory, never vendored, never via direct
Dolt access.** AEGL keeps sole ownership of session continuity, agent rules stay owned by
RuleSync, and Beads owns the long-horizon task graph. A thin bridge stores only *references*
(task IDs, ready count, current claimed task) in `state.json` — never a copy of the graph.
The most important hard constraint discovered: integrating Beads must be **git-invisible and
AEGL-layout-safe**, which the `BEADS_DIR=<repo>/.aegl/beads` + `--stealth` combination
achieves, provided AEGL pre-creates the `.aegl/` parent directory. `[SANDBOX]` `[INFERRED]`

Two facts temper the enthusiasm and drive the "optional + isolated" stance:

1. Beads' **telemetry is enabled by default** (opt-out), endpoint
   `https://gastownhall-eventsapi.com/mp/collect`. It sends only command name/version/OS and
   an HMAC machine id, never issue text, but AEGL must not silently turn this on for users. `[SOURCE]`
2. Beads' **schema and CLI are moving fast** (schema already at v69 in v1.3.1, multiple
   `BREAKING:` changelog entries across 1.2→1.3, and an active "Memory Beads" redesign
   proposal). Reproducibility demands strict version pinning + graceful degradation. `[SOURCE]` `[COMMUNITY]`

---

## Beads Current Version

| Field | Value | Provenance |
|---|---|---|
| Canonical repo | `github.com/gastownhall/beads` | `[OFFICIAL]` |
| Legacy/redirect path | `github.com/steveyegge/beads` (same repo; Go module path still `github.com/steveyegge/beads`) | `[OFFICIAL]` |
| Latest stable release | **v1.3.1**, published **2026-09-30T23:37:36Z** (not a prerelease) | `[OFFICIAL]` |
| Latest tag commit | `c1c4b642ac1c08d8c828007a1c2f96e47e43ef7c` (tag object `89f02da9…`) | `[OFFICIAL]` |
| Binary self-report | `bd version 1.3.1 (c1c4b642a)` | `[SANDBOX]` |
| `main` HEAD at research time | `0588af25d197906203851b9312b1796620328567` (2026-10-02), i.e. **ahead of v1.3.1** | `[SANDBOX]` |
| Prior stable | v1.3.0 (2026-09-15), v1.2.2 (2026-08-15), v1.2.1 (pulled), v1.1.x, v1.0.x, v0.63.x | `[OFFICIAL]` |
| License | **MIT** ("Copyright (c) 2025 Beads Contributors") | `[OFFICIAL]` |
| Bundled third-party | Dolt, go-mysql-server, dolthub/driver — all **Apache-2.0** | `[SOURCE]` |
| Distribution | Homebrew (`brew install beads`), npm (`@beads/bd`), mise, install script, PowerShell script, `go install` (cgo/nocgo), source | `[OFFICIAL]` |
| Linux amd64 artifact | `beads_1.3.1_linux_amd64.tar.gz`, 53,304,363 bytes; extracted `bd` binary **154 MB** (static, bundles Dolt); `checksums.txt` available; SPDX SBOM shipped | `[OFFICIAL]` `[SANDBOX]` |
| Stars / forks (2026-10-02) | ~27,586 / ~1,875 — recorded for context only, **not** a decision input | `[OFFICIAL]` |

The prompt's assumed reference (Beads v1.3.1) is **confirmed correct** by upstream, not
assumed. `main` is two days ahead of the release, so this report anchors to **v1.3.1** and
flags any near-main behavior only where it clarifies direction.

---

## Upstream Evidence

Primary evidence used, in the priority order the task requires:

1. **Releases / tags / assets** — `gh release view v1.3.1`, `git ls-remote --tags`, release
   `checksums.txt`, SHA-256 verified. `[OFFICIAL]`
2. **README + docs site content in-repo** — `README.md`, `docs/architecture/dolt.md`,
   `docs/core-concepts/sync-concepts.md`, `docs/reference/json-schema.md`,
   `docs/cli-reference/*`, `docs/getting-started/installation.md`, `AGENT_INSTRUCTIONS.md`. `[OFFICIAL]`
3. **Source at `c1c4b642`** — `internal/types/types.go`, `internal/idgen/*`,
   `internal/storage/**`, `cmd/bd/{init,prime,ready,memory,dep,setup,hooks,compact}.go`,
   `memoryops/*`, `internal/recipes/*`, embedded migrations. `[SOURCE]`
4. **Official issues** — 7,095 open at research time; top-by-reaction and high-comment
   issues surveyed. `[COMMUNITY]`
5. **This analysis / sandbox** — every CLI behavior was reproduced with the pinned binary. `[SANDBOX]`

Full raw evidence: `docs/research/evidence/beads-v1.3.1-sandbox-evidence.md`.

**Doc-drift warning** (important for anyone reading Beads docs): several auto-generated
CLI docs are **stale vs. the code** in v1.3.1 — notably the `bd init --stealth` help text
and the "proxied-server rooted at `.beads/proxieddb`" line. Where docs and code disagree,
this report follows **the code and the sandbox**. `[SOURCE]`

---

## Current Architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│ bd (single Go binary, ~154 MB, bundles Dolt in-process)               │
│                                                                       │
│   CLI layer        cmd/bd/*            create/ready/update/close/...  │
│   Domain layer     issueops, workapi   lifecycle, readiness, graph    │
│   Storage layer    Dolt (embedded | server | proxied-server)          │
│                    canonical source of truth = the Dolt database      │
│   Memory plane     config table, keys "kv.memory.<key>"               │
│   VCS              Dolt commits (native) ; git = optional transport   │
└───────────────────────────────────────────────────────────────────────┘
        │                         │                         │
   .beads/ dir               git repo (opt)            Dolt remote (opt)
   (or $BEADS_DIR)     hooks, repo discovery,     bd dolt push/pull to
                       refs/dolt/data             any Dolt/git remote
```

Key architectural facts `[SOURCE]` `[SANDBOX]`:

- **Dolt is the only storage backend in v1.3.1.** SQLite/Postgres/MySQL and a `--to-dolt`
  migration were removed. `bd init --backend postgres` prints migration guidance and refuses.
  `.beads/issues.jsonl` is an **export/interchange**, explicitly *not* the source of truth.
- **The workspace lives in `.beads/`**, resolved by walking up from cwd, **or** by the
  `BEADS_DIR` environment variable (highest priority, bypasses discovery).
- **`metadata.json` / `config.yaml` are identity + settings**; the issue data is under
  `.beads/embeddeddolt/<db>/` (embedded) or `.beads/dolt/` (server marker).
- **git is optional.** "Beads works without git. The Dolt database is the storage backend —
  git integration (hooks, repo discovery, identity) is optional." `[OFFICIAL]`
- Older-model artifacts (SQLite `bd.db`, `.db*` files, `db.sqlite`) survive only as
  `.gitignore` legacy patterns and compatibility notes — they are **not** the current model. `[SOURCE]`
- The repo also ships `.beads/`, `.claude/`, `.codex/`, `.cursor/`, `.agents/` integration
  fixtures and its own issue database — i.e. Beads "eats its own dogfood".

What Beads is **not** (avoid the old-version mental model): it is not a markdown-plan
replacement that stores state in Git; it is a Dolt-backed relational graph with an optional
git transport. `[SOURCE]`

---

## Data Model

Beads has **one core entity: the Issue ("bead")**. Epics, subtasks, messages, decisions,
molecules are all rows in `issues` (or the ephemeral `wisps` plane) distinguished by
`issue_type`. `[SOURCE]`

### Entities and fields

| Concept | Realized as | Notes |
|---|---|---|
| Issue / task | row in `issues` | `id, title, description, design, acceptance_criteria, notes, status, priority, issue_type, assignee, owner, created_at, started_at, closed_at, close_reason, closed_by_session, external_ref, spec_id, metadata(JSON), due_at, defer_until, pinned, compaction_level…` |
| Epic / subtask | `issue_type=epic` + `parent-child` dependency; child IDs are dotted (`bd-a3f8.1`, `bd-a3f8.1.1`), max depth 3 | hierarchy is a dependency, not a table |
| Issue types | `bug feature task epic chore decision message molecule gate spike story milestone` (+ internal `event`) | `decision` is a first-class ADR type |
| Status | `open in_progress blocked deferred closed pinned hooked` (+ custom via `status.custom` with categories active/wip/done/frozen) | `blocked` status ≠ computed `is_blocked` |
| Priority | integer **0–4** (default 2) | P0 highest |
| Assignee / owner | `assignee VARCHAR`, `owner VARCHAR` | claim sets assignee |
| Labels | `labels(issue_id,label)` table | AND/OR/glob/regex filters |
| Dependencies | `dependencies` table (typed edges) | see below |
| Comments / audit | `comments` table + `events` mutation-audit table | `bd history` |
| Messages / threads | `issue_type=message` + `replies-to` edges + `thread_id`; ephemeral/wisp lifecycle | `bd mail` is only a delegate shim |
| Molecules / formulas | issues with `is_template=true`; `.formula.toml/.json` compiled to issues | template/steps system |
| Memories | **no table** — rows in the `config` table under key prefix `kv.memory.<key>` | plain key→value string |
| Provenance | `provenance_events` table (issue ↔ git SHA/PR binding) | |

### ID model (hash-based IDs)

`[SOURCE]` `bd-<base36(sha256(title|description|creator|createdAt_nano|nonce))>`, length
3–8 chosen adaptively (default target ≥3, birthday-paradox collision math), per-length
nonce probing with a live `COUNT(*)` check. Default prefix is `bd`, overridable (`-p`).

- IDs are **collision-free without coordination**, but **not reproducible**: the hash
  includes nanosecond timestamp + actor, so two agents creating "the same" task get
  different IDs by design.
- **Hierarchical IDs** are pure string construction (`<parent>.<n>`) with a per-store
  `child_counters` table — a known fork/merge drift source (Beads ships
  `ReconcileChildCounters` for it).
- **Dependency row PKs are deterministic UUIDv5** of `(issue_id, target)` → merge-safe.
- A `counter` ID mode exists but is explicitly **not merge-safe** (docs say two branches
  can mint the same `bd-7`).

### Status lifecycle

`open → in_progress (claim) → closed`, with `bd reopen`, `bd close --force`, and guarded
close policy (refuses to close with open children or a live blocker unless forced).
`deferred`/`defer_until` hide work from ready until a time. Ephemeral `wisps` are excluded
from ready and purge-eligible. `[SOURCE]`

### Mapping to AEGL continuity fields

This is the crux for v1.4. AEGL's `work` block has eight semantic fields. Their fit to
native Beads constructs `[SOURCE]` `[INFERRED]`:

| AEGL field | Beads native? | Where it goes | Verdict |
|---|---|---|---|
| `completed` | **exact** | `status=closed` + `closed_at/close_reason` | **Beads owns** |
| `inProgress` | **exact** | `status=in_progress` (claim) + `assignee` | **Beads owns** |
| `blocked` | **exact (2 facets)** | stored `status=blocked` **and** computed `is_blocked` from edges | **Beads owns** |
| `goal` | no native field | nearest: an `epic` (with acceptance criteria) — but an epic is closable work, not a pure goal | **AEGL keeps** (session goal); optionally mirror as an epic |
| `nextAction` | **not native** | Beads answers "next" as a *derived graph query* (`bd ready`), not a stored field | **AEGL keeps**; bridge may attach `bd ready` output |
| `importantDecisions` | **native** | `issue_type=decision` (ADR) with required sections | **Beads owns** long-horizon decisions; AEGL may keep the session-local one |
| `failedApproaches` | **not native** | no entity; nearest: a comment, a `decision`'s "Alternatives Considered", or `metadata` | **AEGL keeps**; promote durable ones to a memory |
| `doNotRepeat` | **not native** | no negative-constraint construct; nearest: a persistent memory | **split**: session-local stays in AEGL; durable constraint → Beads memory |

**Conclusion:** Beads natively models exactly the *task-state* trio (`completed`,
`inProgress`, `blocked`) plus decisions and the dependency DAG. It does **not** natively
model goal, next-action, failed-approaches, or do-not-repeat; those stay AEGL (session) or
become Beads *memories* (durable). AEGL must **not** force all eight fields into Beads. `[INFERRED]`

---

## Storage Model

`[SOURCE]` `[SANDBOX]`

- **Canonical source of truth: the local Dolt database.** Not JSONL.
- Embedded default on disk: `.beads/embeddeddolt/<db>/` (contains `.dolt/noms/…`).
- Server mode marker: `.beads/dolt/` (data on the `dolt sql-server`).
- `.beads/issues.jsonl` = export/interchange only ("Do not use routine `bd import` as a
  replacement for `bd dolt pull`"). `bd export --all` and `bd export --jsonl` produce it.
- Config is `config.yaml` (+ `config.local.yaml`), **not JSON**. `metadata.json` holds
  backend/identity:
  ```json
  {"database":"dolt","backend":"dolt","dolt_mode":"embedded","dolt_database":"aegl","project_id":"…"}
  ```
- **`dolt_database` name is derived from the current directory basename** (or `-p` prefix),
  not from `BEADS_DIR`'s basename — observed: cwd `nogit` → `dolt_database: nogit`. `[SANDBOX]`
- Size: a fresh store with a handful of issues is **~2.1 MB**; the executable itself is
  ~154 MB. `[SANDBOX]`
- `.beads/.gitignore` (internal) ignores `embeddeddolt/`, `dolt/`, locks, sockets, the
  credential key, backups, etc. `metadata.json` and `config.yaml` are **tracked by git by
  default** (in non-stealth mode). `[SOURCE]`

---

## Dolt Architecture

`[SOURCE]` `[OFFICIAL]`

- **Why Dolt:** version-controlled SQL with **cell-level merge** (not line-based), native
  branching independent of git, built-in per-write commits, and a single-binary embedded
  mode. Linked in-process via `github.com/dolthub/driver/v2` + `dolthub/dolt/go`.
- **Modes (3 + shared):**
  - `embedded` (default) — data `.beads/embeddeddolt/`, **single writer**, file-locked.
  - `server` (`bd init --server`) — external `dolt sql-server`, `.beads/dolt/`, multi-writer.
  - `proxied-server` (**EXPERIMENTAL**) — per-workspace proxy fronting a child dolt server.
  - `shared-server` — one server on port 3308 for many projects under `~/.beads/shared-server/`.
- **Commands exposing version control:** `bd branch`, `bd vc {status,commit,merge,diff}`,
  `bd history`, `bd diff`, `bd conflicts`, `bd dolt {remote,push,pull,commit,start,stop}`,
  `bd backup`, `bd prune`/`bd purge`, `bd gc`, `bd compact`. (There is **no** `bd dolt branch`
  / `bd dolt merge`.)
- **Schema migration:** embedded SQL migrations (69 files in v1.3.1 → schema **v69**),
  cursor table `schema_migrations`, run automatically on writable open. Guard rails:
  `SchemaSkewError` (DB ahead of binary → actionable error, escape hatch
  `BD_IGNORE_SCHEMA_SKEW=1`), `SchemaBehindError` (read-only open can't migrate),
  a remote-migrate gate that refuses auto-applying migrations against shared/remote stores,
  and a `MIGRATION-FREEZE` file (exit 14).
- **Locks/gates:** a two-level `flock` gate serializes operations; gate files are
  `BEADS_DIR.gate.lock` (sibling of the DB dir) and `.beads/embeddeddolt.gate.lock`.
  This is why the `BEADS_DIR` parent must pre-exist. `[SANDBOX]`

**AEGL stance:** treat Dolt as an **implementation detail of Beads**. AEGL must not open,
query, or migrate the Dolt DB directly. AEGL speaks only the `bd` CLI. `[INFERRED]`

---

## Git Integration

`[SOURCE]` `[SANDBOX]`

git is **optional**; three couples exist and they are separable:

1. **Repo discovery / identity** — `bd` walks up for `.git` to find a role (`beads.role`) and
   to locate a workspace. `BEADS_DIR` bypasses this.
2. **git hooks** — default `bd init` installs `pre-commit, post-merge, pre-push,
   post-checkout, prepare-commit-msg` into `.beads/hooks/` and sets
   `git config core.hooksPath=<repo>/.beads/hooks`. **This mutates the repo's git config.**
3. **Dolt transport over git** — `bd dolt push/pull` to `refs/dolt/data` on a Dolt remote
   (which may be the same `origin` URL as the code). In v1.3.1 this **no longer auto-adopts
   a git origin without consent** (`--yes` or interactive confirm; fails closed non-interactively) —
   a good security fix. `[SOURCE]`

What `bd init` (default) modifies in a clean git repo `[SANDBOX]`:

```
created: .beads/**, .beads.gate.lock, AGENTS.md, CLAUDE.md,
         .claude/settings.json, .codex/{config.toml,hooks.json},
         .cursor/{hooks.json,rules/beads.mdc}, .agents/skills/beads/**,
         .gitignore (rewritten: "# Beads / Dolt files (added by bd init)")
modified git config: core.hooksPath, beads.role
created git commit: "bd init: initialize beads issue tracking"
```

There is **no** `.gitattributes` merge driver in v1.3.1 (removed; `--skip-merge-driver` is not
a real flag). `refs/dolt/data` is a Dolt remote ref, not a git working-tree concern.

---

## Git-Free / Stealth Mode

`[SOURCE]` `[SANDBOX]`

`bd init --stealth` sets `no-git-ops: true` in `config.yaml` and means **"invisible in git"**,
not "data outside the repo". Concretely it:

- writes stealth patterns to **`.git/info/exclude`** (`.beads/`, `.claude/settings.local.json`,
  `.dolt/`, `*.db`, `.beads-credential-key`, `.beads/proxieddb/`, `*.gate.lock*`);
- **skips git hook installation** (no `core.hooksPath` change);
- **does not touch** AGENTS.md / CLAUDE.md / `.claude` / `.codex` / `.cursor`;
- **makes no git commit**;
- still creates `.beads/` **inside** the repo.

So stealth alone keeps the DB in-tree but git-invisible. **Full physical isolation requires
`BEADS_DIR`** (next section). `bd init --stealth` still runs `git init` if there is no repo
unless `BEADS_DIR` is set. `[SOURCE]`

---

## BEADS_DIR Experiment

`[SANDBOX]` — reproduced; see evidence §4–§5.

- `BEADS_DIR` **is the `.beads` directory itself**, canonicalized, and it **bypasses
  workspace discovery entirely** (no cwd walk). `bd init` also skips `git init` when it is set.
- `$BEADS_DIR/config.yaml` is the **highest-priority** config source.
- **Experiment (external, non-git cwd):** `BEADS_DIR=<dir>/beads`, cwd a non-git folder →
  `bd init --stealth` created everything under `BEADS_DIR`, **left cwd untouched**, and all
  core commands (`create/ready/remember/prime`) worked. ✅
- **Experiment (AEGL-shaped):** git repo + `BEADS_DIR=<repo>/.aegl/beads` + `--stealth` →
  only `.aegl/` appears in the repo, `core.hooksPath` untouched, `.git/info/exclude` gets
  stealth patterns, `.aegl/beads.gate.lock` present, `bd where`/`context`/`info` all resolve
  to the external dir. ✅
- **Failure discovered:** pointing `BEADS_DIR` at `<repo>/.aegl/beads` when `<repo>/.aegl/`
  does **not** exist makes `bd init` abort:
  `workspacegate: gate parent <repo>/.aegl/ must exist`. **AEGL must `mkdir -p .aegl` before
  init.** ✅ (this is a required building block of the v1.4 install flow)

**Decision implication:** `BEADS_DIR=<repo>/.aegl/beads` + `bd init --stealth` is the correct
isolation primitive for AEGL — it satisfies AEGL's "do not pollute the target project"
principle while keeping the DB discoverable and portable (the whole `.aegl/` can be moved or
backed up). `[INFERRED]`

---

## Core CLI

`[SANDBOX]` (help + live behavior). Command groups in v1.3.1 include: work
(`create/ready/list/show/update/close/reopen/dep/query/search/graph/tree/children/epic/swarm`),
memory (`remember/memories/forget/recall`), setup (`init/setup/config/hooks/bootstrap/dolt`),
sync (`sync/dolt/export/import/backup/restore`), observability
(`status/info/where/context/doctor/history/diff/events`), and advanced
(`gate/molecule/formula/mail/provenance/federation/serve`). Notable flags AEGL will use:

| Need | Command |
|---|---|
| Machine-readable list/detail | `bd ready --json`, `bd list --json`, `bd show <id> --json` |
| Ready explanation | `bd ready --explain` |
| Atomic take | `bd update <id> --claim` (or `bd ready --claim`) |
| Link work | `bd dep add <blocked> <blocker>` / `bd dep <blocker> --blocks <blocked>` |
| Memory | `bd remember "text" [--key k]`, `bd memories`, `bd forget <key>`, `bd recall <key>` |
| Context inject | `bd prime` (no `--json`; has `--hook-json`, `--memories-only`, `--no-memories`) |
| Identity/debug | `bd where`, `bd context`, `bd info`, `bd --version` |
| Interchange | `bd export --all` (JSONL, includes `{"_type":"memory",…}`) |

`bd doctor` is **not supported in embedded mode** (only `--check=artifacts|conventions|pollution`),
so AEGL cannot rely on it for health checks. `[SANDBOX]`

---

## bd prime

`[SOURCE]` `[SANDBOX]` — this is the highest-value section for the overlap question.

`bd prime` outputs **AI-optimized markdown workflow context**. Two modes: CLI (~1–2k tokens)
and MCP (~50 tokens when a beads MCP server is detected). Flags: `--full`, `--mcp`,
`--stealth`, `--export`, `--memories-only`, `--no-memories`, `--hook-json`,
`--max-memories N`, `--max-memory-chars N`. A custom `.beads/PRIME.md` overrides the static
body (memories are still appended).

**What full CLI mode actually contains** (measured: 5,445 bytes / 121 lines / 826 words for
3 memories), in order:

1. A truncation directive ("if this output is truncated, read the full persisted hook output").
2. `# Beads Workflow Context`.
3. `## Persistent Memories (N)` — near the top, only if memories exist.
4. `# 🚨 SESSION CLOSE PROTOCOL 🚨` + checklist + policy note.
5. `## Core Rules` (including "use bd for ALL task tracking — do NOT use TodoWrite / markdown
   TODO lists", and a **hardcoded anti-MEMORY.md line**).
6. `## Essential Commands` (Finding Work / Creating & Updating / Dependencies & Blocking /
   Sync & Collaboration / Project Health / Quality Tools / Lifecycle & Hygiene / Structured
   Workflows).
7. `## Common Workflows` (Starting / Completing / Creating dependent work).
8. A divergence reminder if both AGENTS.md and CLAUDE.md carry independent bd blocks.

**Critical negative finding (verified): `bd prime` does NOT query the issue database for
ready / in-progress / blocked work.** Its only DB read is the memory list. Everything else is
static template text + cheap git/remote probes. With no workspace it exits 0, prints nothing.
`--memories-only` yields just the truncation line + the memories section (625 bytes on our sample).

**Overlap answer:** `aegl resume` and `bd prime` are **mostly disjoint**:

| | `aegl resume` | `bd prime` |
|---|---|---|
| Kind | deterministic repo/session check | static workflow cheat-sheet + memories |
| Unique content | branch/HEAD/version/dirty/CI, goal, next action, HANDOFF validity | bd command reference, session-close protocol, persistent memories |
| Work graph | no | **no** (surprisingly) |
| Token cost | small | ~1–2k (CLI) |

The only true overlap is **persistent memories** (both can surface durable project facts) and
**"what to do next"** (AEGL's `next.action` vs Beads' *implied* workflow guidance). There is
**no duplication of the work graph**, because `bd prime` doesn't print it. `[INFERRED]`

---

## bd ready

`[SOURCE]` `[SANDBOX]`

- Ready = open (or active custom) **and** unblocked **and** unpinned **and** not
  deferred/ephemeral/hooked, computed from the materialized `is_blocked` column (transitive:
  `blocks`, `conditional-blocks`, `waits-for`, plus inherited `parent-child` descendants of a
  blocked row).
- **Not** a topological ordering. Default sort is `priority ASC, created_at ASC, id ASC`
  (alternatives: `hybrid`, `oldest`).
- Flags: `--json`, `--limit` (default 100), `--explain`, `--assignee`/`--unassigned`,
  `--claim` (atomically claim the first match), `--brief`, `--parent`, `--include-deferred`,
  `--include-ephemeral`, label/type/metadata filters, `--max-rows` (CI circuit-breaker).
- `--explain` prints Ready / Blocked / Cycles with reasons and "unblocks N".
- **Sandbox DAG verification:** with A→B→C, ready returned only A; after claiming A, none;
  after closing A, B; after closing B, C. **Beads fully solves the dependency DAG + ready
  queue.** `[SANDBOX]`

**Answer to "should AEGL implement its own task DAG?" → No.** Beads' ready semantics are
mature and empirically correct; AEGL must **not** re-implement a scheduler. `[INFERRED]`

---

## Persistent Memory

`[SOURCE]` `[SANDBOX]`

- **Storage:** rows in the **`config` table**, key `kv.memory.<key>`. Not a table, not a
  special issue type, not JSON files.
- **Schema:** a memory is **exactly a key → value string**. There is **no** priority, scope,
  tags, creation/update timestamp, source issue, or expiry — the source even notes "the memory
  store keeps no timestamps, so alphabetical is the only stable order available".
- **Key derivation:** if `--key` is omitted, the key is auto-derived from the content
  (lowercased, non-alphanumerics → `-`, capped 60 bytes). A bare arg matching an existing key is
  **recalled**, not stored.
- **Selection / injection:** `bd prime` lists **all** memories, alphabetically, capped only by
  `--max-memories` / `--max-memory-chars` (whole-memory boundaries; at least one always emitted).
- **Dedup / decay / TTL:** none. Same key overwrites in place; on Dolt pull, a
  `kv.memory.*` conflict auto-resolves "theirs" (remote wins). No compaction of memories, no TTL.
- **Compaction** (`bd admin compact`) is about **old closed issues**, not memories: Tier-1
  AI-summarizes closed issues older than 30 days, snapshots the original, overwrites the
  description; Tier-2 is declared but unimplemented; it is **manual only**, never triggered by
  `prime`/hooks, and requires server mode.
- **Shape:** "long-term facts database", "simple note", or "task graph issue"? → **None of
  those exactly.** It is a **flat, namespaced key→value fact store** with a session-start
  injection path — closer to a "project facts" KV than to the issue graph. `[INFERRED]`

**Risks for AEGL:** the memory plane is actively being **redesigned** — open proposal
#5877 "Memory Beads" (112 comments, Revision 4) proposes promoting memories to first-class
entities with keys that resolve to canonical IDs and Link/Reference semantics. Pinning matters. `[COMMUNITY]`

AEGL must also enforce **secret redaction before writing** any `bd remember`, because Beads
performs **no redaction of its own**. `[INFERRED]`

---

## Dependencies

`[SOURCE]`

- Typed edges live in the `dependencies` table; **19 well-known types**: workflow
  (`blocks`, `parent-child`, `conditional-blocks`, `waits-for`), associations
  (`related`, `discovered-from`, `authored-by`, `assigned-to`, `approved-by`, `attests`,
  `tracks`, `until`, `caused-by`, `validates`, `delegated-from`), and graph links
  (`replies-to`, `relates-to`, `duplicates`, `supersedes`).
- The type set is **open** (any non-empty string ≤32 chars), not a closed enum.
- Readiness-affecting types: `blocks`, `conditional-blocks`, `waits-for` (hard blockers) and
  `parent-child` (inherited blocking). `relates-to`/`duplicates`/`supersedes`/`replies-to` do
  **not** affect readiness.
- `bd dep add <child> <parent>` = **"child depends on parent"**; the mirror is
  `bd dep <blocker> --blocks <blocked>`. Default type is `blocks` (with an advisory warning).
  All-or-nothing add; cycle checks; hierarchy depth ≤ 3.
- Known semantic bug: **#5577** — `conditional-blocks` currently unblocks on *any* close of the
  precondition, not only on failure, defeating its documented semantics (priority/p1). `[COMMUNITY]`

---

## Multi-Agent Claiming

`[SOURCE]` `[SANDBOX]`

- `bd update <id> --claim` sets `assignee=actor` **and** `status=in_progress` in one guarded
  write. Idempotent for the same actor; **refused for a different actor**:
  `Error: issue already claimed by alice`. `[SANDBOX]`
- Claim eligibility: built-in `open` (or a configured active status), unassigned or assigned to
  the actor/pool. `bd ready --claim` atomically claims the first matching ready issue.
- **Hash IDs are the multi-agent safety mechanism** — no coordination needed for creation; and
  **dependency row PKs are deterministic UUIDv5**, so edges merge cleanly.
- **Dolt** provides the merge substrate: cell-level merges, native branches (`bd branch`,
  `bd vc merge`), and `is_blocked` recomputation after merge/close.
- **Concurrency model caveat:** embedded Dolt is **single-writer** (file-locked); true
  concurrent multi-writer requires **server mode** (`dolt sql-server`). `[SOURCE]`
- There are also `bd lease`/`heartbeat`/`reclaim` mechanisms for dead-worker recovery. `[SOURCE]`

**Answer to "AEGL multi-agent coordination: self-implement or build on Beads?" → build on
Beads (later, v1.5+), don't re-implement.** Claiming + DAG + merge already exist. AEGL should
not, in v1.4, attempt multi-agent scheduling. `[INFERRED]`

---

## Agent Integrations

`[SOURCE]` `[SANDBOX]`

`bd setup <recipe>` is a recipe installer. Built-ins: `aider claude codex cody copilot cursor
factory gemini junie kilocode kiro mux opencode windsurf`. `bd setup --list` enumerates them;
each supports `--check` and `--remove` (no `--dry-run`, no `--force`).

What each writes (conflict-relevant):

| Recipe | Files |
|---|---|
| `claude` | `.claude/settings.json` (SessionStart hook), CLAUDE.md (or AGENTS.md) block |
| `codex` | `.codex/config.toml`, `.codex/hooks.json`, `.agents/skills/beads/**`, AGENTS.md block |
| `cursor` | `.cursor/rules/beads.mdc`, `.cursor/hooks.json`, `.agents/skills/beads/**` |
| `factory` / `opencode` / `mux` | AGENTS.md managed section (mux adds shell hooks) |
| `gemini` | `.gemini/settings.json`, GEMINI.md section |
| `copilot` / `aider` / `junie` / `windsurf` / `cody` / `kilocode` / `kiro` | editor rules / plugin / config files |

Markers (use these to detect and de-duplicate) `[SOURCE]`:

```
AGENTS.md / CLAUDE.md : <!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:… -->  … <!-- END BEADS INTEGRATION -->
Codex second block     : <!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->  … <!-- END BEADS CODEX SETUP -->
Cursor rules file      : .cursor/rules/beads.mdc   (bare <!-- BEGIN BEADS INTEGRATION -->)
Mux shell hook         : # BEGIN BEADS MUX HOOK … # END BEADS MUX HOOK
Git hooks (separate)   : # --- BEGIN BEADS INTEGRATION v<ver> ---
```

**`bd init` writes AGENTS.md by default and auto-installs Claude + Codex + Cursor.** So with
AEGL's RuleSync also owning AGENTS.md/CLAUDE.md/Cursor rules, running plain `bd init` in a
target project is a **direct collision**. Detection substring to avoid double injection:
`<!-- BEGIN BEADS INTEGRATION`. `[SOURCE]` `[SANDBOX]`

---

## Hooks

`[SOURCE]`

- **Claude Code:** `SessionStart` → `bd prime --hook-json` (and `bd prime --stealth --hook-json`
  in stealth). PreCompact is deliberately *removed*/migrated away, because SessionStart also
  fires after compaction.
- **Gemini:** `SessionStart` → `bd prime --hook-json` (PreCompress intentionally not registered).
- **Codex:** `.codex/hooks.json` with `SessionStart`, `PreCompact`, `PostCompact`,
  `UserPromptSubmit` → `bd codex-hook <event>` (which re-execs `bd prime` under a closed
  allowlist and a 30 s timeout; refresh markers live in the user cache/temp dir, never in the repo).
- **Cursor:** `.cursor/hooks.json` with `sessionStart`, `preCompact`, `postToolUse` →
  `bd cursor-hook <event>`.
- **Mux:** shell scripts `.mux/init` (`bd prime --stealth`), `.mux/tool_post` (`bd dolt push`),
  `.mux/tool_env`.
- `.beads/hooks/` is the **git-hooks** location (`bd hooks install`), **not** agent hooks.
  `bd hooks install` installs git hooks; `bd setup <agent>` installs the context-injection hooks.

**Coexistence with AEGL:** AEGL v1.3 has **no agent hooks** (handoff is manual). Beads hooks
inject `bd prime` (workflow + memories). If AEGL later adds session-end/session-start hooks,
they must be **AEGL-owned** and must not double-inject the same content. Since `bd prime`
doesn't print the work graph and AEGL resume doesn't print bd commands, the two inject
**mostly disjoint** context — coexistence is feasible but must be **explicitly budgeted**;
two SessionStart hooks in one agent is a context-cost and ordering hazard. `[INFERRED]`

---

## RuleSync Conflict Analysis

AEGL already has RuleSync generating agent rules into AGENTS.md / CLAUDE.md / Cursor rules.
Beads' `bd init` and `bd setup` **also** write to those files. This is the sharpest collision.

Findings that matter `[SOURCE]` `[SANDBOX]`:

- `bd init` (non-stealth, non-`--skip-agents`) writes an AGENTS.md block **and** a second
  Codex block, and installs `.claude`/`.codex`/`.cursor` files → **RuleSync and Beads would
  both claim AGENTS.md**.
- Running `bd setup codex` on a file that already has the standard block produces **two
  `## Beads Issue Tracker` sections** (community bug #5161) — evidence that even Beads' own
  marker logic is fragile across recipes.
- Beads inserts *imperative* rules that conflict with AEGL's model: "use bd for ALL task
  tracking — do NOT use TodoWrite or markdown TODO lists", plus a hardcoded anti-`MEMORY.md`
  line that users cannot configure (#5169).
- Community report #5655: `bd init` scaffolds **every** supported agent tool unconditionally,
  with no detection — exactly the behavior AEGL must avoid in a "非侵入 target project" design.

**Recommendation:** **RuleSync remains the single source of truth for agent instructions.**
AEGL should **not** run `bd setup <agent>` and should **not** run a default `bd init`.
Instead:

- Initialize Beads with **`bd init --stealth`** (never touches agent files) and/or
  **`--skip-agents --skip-hooks`**, pointed at `BEADS_DIR=<repo>/.aegl/beads`.
- Let **RuleSync emit a single, AEGL-authored guidance line** referencing Beads (e.g. "This
  project may use `bd` for long-horizon work; run `bd ready` / `bd show <id>`; durable facts
  live in `bd remember`"). One owner, one block. `[INFERRED]`

---

## AEGL Continuity Current Responsibilities

Verified against the v1.3.0 tree `[SOURCE]`. CLI: `aegl status | handoff | resume |
continuity {history,check}` (plus non-continuity `adapters|version|inspect|attach|verify|detach`).
`--root` (default = AEGL repo) + `--json` on every continuity command.

**`state.json` (canonical machine truth, schemaVersion 1):**

```
project{name,version}
repository{branch,head,dirty,remote,latestCommit,latestTag}
ci{status,runId,headSha,url,checkedAt}
phase{name,status}
work{goal,currentTask, completed, inProgress, blocked, failedApproaches,
     importantDecisions, doNotRepeat, knownRisks, openQuestions}
next{action,command}
```

**Projections:** `HANDOFF.md` (warm, ~14 sections) and `NEXT-SESSION.md` (hot, short).
**Cold:** `history/<ts>.{json,md}` (immutable, pruned to `historyLimit`), `events.jsonl`
(append-only, 3 of 10 declared types actually emitted). **Config:** `.aegl/continuity/config.json`
with `historyLimit, commitCurrentState, commitHistory, includeCi, redactSecrets, memoryBackend`.
**Redaction:** `secrets.py` (5 regex families + `$HOME` normalization), applied to the whole
snapshot before persisting → state.json + both markdown files + events. **Gitignore:**
`.aegl/continuity/` is ignored → **no cross-machine sync**; a fresh clone has no handoff.

**The reserved seam** (`core/continuity/memory.py`) — quoted verbatim in the evidence/aAppendix:

```python
class PersistentMemoryBackend:
    name = "none"
    def available(self) -> bool: return False
    def store(self, root: Path, snapshot: dict) -> None: ...
    def query(self, root: Path) -> list[dict]: return []

class NoneBackend(PersistentMemoryBackend):
    name = "none"

def load_backend(config: dict | None) -> PersistentMemoryBackend:
    requested = (config or {}).get("memoryBackend", "none")
    return NoneBackend()
```

Only **one call site** exists: `commands.do_handoff` → `memory.load_backend(cfg).store(root, snapshot)`.
`available()` and `query()` are **never called**. There is **no registry, no plugin discovery,
no `adapters/memory/` directory** yet (the build plan §18 reserves `adapters/memory/beads/`).

**What AEGL already solves:** hot/warm session continuity — "how does *this* checkout hand off
to the *next* agent, deterministically, with secret redaction, without polluting git."
**What it does not solve:** long-horizon work items, dependencies, blockers, durable project
memory shared across sessions/machines. That is exactly Beads' domain.

---

## Responsibility Matrix

Legend: **AEGL** = AEGL owns it; **Beads** = Beads owns it; **Bridge** = AEGL stores a
reference/summary; **None** = do not connect.

| Capability | AEGL v1.3 | Beads v1.3.1 | Who should own | Mechanism |
|---|---|---|---|---|
| Current git state (branch/HEAD/dirty/remote) | yes (`repository`) | incidental (repo discovery) | **AEGL** | AEGL only |
| Current branch / HEAD | yes | no | **AEGL** | AEGL only |
| Current VERSION | yes | no | **AEGL** | AEGL only |
| CI status | best-effort (`gh`) | no | **AEGL** | AEGL only |
| Session handoff | yes (`HANDOFF.md`) | no | **AEGL** | AEGL only |
| NEXT-SESSION (hot) | yes | no | **AEGL** | AEGL only |
| Current goal | yes (`work.goal`) | no native | **AEGL** (session) | optional epic mirror |
| Next action | yes (`next.action`/`command`) | derived (`bd ready`) | **AEGL** (session) + Bridge ready summary | Bridge |
| Completed tasks | yes (list) | native (`closed`) | **Beads** (long-horizon) | Bridge ref |
| Open tasks | yes (list) | native (`open`) | **Beads** | Bridge ref |
| Blocked tasks | yes (list) | native (`blocked`/`is_blocked`) | **Beads** | Bridge ref |
| Dependency DAG | no | **yes** | **Beads** | AEGL never re-implements |
| Persistent memory | reserved (none) | yes (`kv.memory.*`) | **Beads** (durable) | Bridge |
| Important decisions | yes (list) | native (`decision` type) | **Beads** (durable); AEGL keeps session-local | Bridge |
| Failed approaches | yes (`failedApproaches`) | no native | **AEGL**; promote durable → memory | Bridge |
| doNotRepeat | yes | no native | **split** session (AEGL) / durable (memory) | Bridge |
| Multi-agent claim | no | **yes** (`--claim`) | **Beads** (v1.5+) | none in v1.4 |
| Cross-machine sync | **no** (gitignored) | yes (`bd dolt push/pull`) | **Beads** | AEGL documents, does not proxy |
| History / event log | yes (session-scoped) | yes (issue-level Dolt history) | **separate** — AEGL session history, Beads issue history | none |
| Context injection | no hooks yet | `bd prime` hooks | **AEGL owns hooks; Beads optional** | explicit budget |
| Agent rules (AGENTS.md…) | RuleSync | `bd init`/`setup` | **RuleSync** | AEGL forbids bd agent setup |
| Secret redaction | yes | **no** | **AEGL** (must redact before bd writes) | Bridge |
| Release state / tags | yes | no | **AEGL** | AEGL only |
| Quality gates | yes (CI) | no | **AEGL** | AEGL only |

---

## Source-of-Truth Boundaries

The central risk is **two task systems**. The rule:

> **AEGL Continuity owns repository/session state. Beads owns the long-horizon work graph.
> Neither stores the other's canonical data. The bridge is reference-only.**

Resolve the collision `state.json: completed=[X]` vs `beads: X=open` as follows `[INFERRED]`:

- `state.json` **must not** carry a per-task work graph. Its `work.completed/inProgress/blocked`
  lists describe the **current session**, not the long-horizon backlog.
- Beads is the **single source of truth for task status** when the backend is enabled.
- `state.json` may carry a **summary/reference block** (never a copy):
  ```json
  "memory": { "backend": "beads", "enabled": true, "beadsVersion": "1.3.1",
               "ready": 3, "open": 12, "blocked": 5, "inProgress": 1,
               "currentTask": "bd-a1b2", "checkedAt": "…" }
  ```
- The bridge never round-trips: AEGL **reads** Beads for the summary and **writes** only
  explicitly requested items (a new memory, a status change), never "the whole graph".

This is the "reference, not replication" principle the task asks us to design for. `[INFERRED]`

---

## Proposed PersistentMemoryBackend

Extend the existing seam without changing its spirit. Keep the v1.3 base class for
compatibility (`name`, `available`, `store`, `query`), and add a **narrow, read-mostly**
contract that maps to the Beads CLI, not to all of Beads. `[INFERRED]`

```python
# core/continuity/memory.py (extended)
class PersistentMemoryBackend:
    name = "none"
    def available(self) -> bool: ...
    def store(self, root: Path, snapshot: dict) -> None: ...   # handoff hook (unchanged)
    def query(self, root: Path) -> list[dict]: ...             # unchanged

class BeadsMemoryBackend(PersistentMemoryBackend):
    name = "beads"

    # Discovery / capability
    def available(self) -> bool: ...            # bd on PATH AND workspace resolves AND version in range
    def version(self) -> str | None: ...        # parse `bd --version`
    def workspace(self) -> dict | None: ...     # from `bd where`/`bd context`

    # Read (used by resume/status)
    def ready(self, limit: int = 10) -> list[dict]: ...   # `bd ready --json --limit N`
    def summary(self) -> dict: ...                        # open/in_progress/blocked/ready counts
    def current_work(self) -> dict | None: ...            # issue assigned to actor & in_progress
    def memories(self) -> dict[str, str]: ...             # `bd memories` -> {key: value}

    # Write (used by handoff / explicit agent action ONLY)
    def remember(self, key: str, content: str) -> None: ...   # redacted content; `bd remember`
    def forget(self, key: str) -> None: ...                    # `bd forget`

    # Deliberately NOT exposed in v1.4: create/claim/close/dep/sync.
```

Design rules:

- **Thin.** Every method is one `subprocess.run(["bd", …])` with a timeout, parsed from
  `--json`. No direct Dolt access, no shell interpolation, no user-controlled argv.
- **Narrow.** v1.4 exposes *read + remember/forget*. Task creation/claiming stays with the
  agent using `bd` directly (or a later version). Do not mirror the whole CLI.
- **Fail-soft.** Every method returns empty/`None`/raises a domain error on any failure; the
  Continuity Layer never depends on it.
- **Redacting.** `remember()` runs `secrets.clean_text()` before calling `bd`.
- **Environment-controlled.** The adapter sets `BEADS_DIR` (from config) and, unless the user
  opted in, `BD_DISABLE_METRICS=1` + `DO_NOT_TRACK=1` on every invocation. (Design note: make
  this explicit and documented, never silent.)

`load_backend` becomes a registry:
`{"none": NoneBackend, "beads": BeadsMemoryBackend}` with unknown values falling back to
`none` (preserving v1.3 "never error on config").

---

## Proposed Data Flow

```
                 reads                          reads
   ┌────────────┐      ┌──────────────────┐        ┌───────────────┐
   │  AEGL      │─────▶│ .aegl/continuity │        │  Beads (bd)   │
   │ resume/    │      │ state.json       │        │  DAG + memory │
   │ status/    │◀─────│ HANDOFF/NEXT     │        │  via BEADS_DIR│
   │ handoff    │      │ events/history   │        │ = .aegl/beads │
   └─────┬──────┘      └──────────────────┘        └───────▲───────┘
         │                        ▲                        │
         │ writes session facts   │ reference summary      │ agent runs
         │ (goal/next/doNotRepeat)│ (ids, counts)          │ bd ready/show/claim
         ▼                        │                        │
     [ AEGL owns ]          [ bridge: read-only ]     [ agent + Beads own ]
```

Who reads/writes what:

- **AEGL writes** `state.json`/`HANDOFF.md`/`NEXT-SESSION.md`/`events.jsonl`/`history/` — its own.
- **AEGL reads** Beads via the adapter to build the `memory` summary block (read-only).
- **AEGL writes** Beads only via explicit `aegl memory remember/forget` (or `handoff --remember`).
- **The agent writes** Beads directly with `bd` (create/claim/close/dep) — AEGL does not proxy
  the whole lifecycle.
- **Neither copies the other's canonical data.**

---

## Proposed New-Session Flow

Goal: one entry point (`./bin/aegl resume`) that yields repository state + session goal +
optional work/memory context, **without duplicating** what `bd prime` already injects.

```
New session
   │
   ▼
./bin/aegl resume
   │
   ├─ (1) AEGL: branch/HEAD/version/dirty/CI + HANDOFF VALID/STALE + next.action
   │        + DO NOT REPEAT      ← AEGL-native, small, deterministic
   │
   ├─ (2) if memoryBackend == "beads" and adapter.available():
   │        ├─ ready(limit)      ← `bd ready --json --limit 10`   (compact list)
   │        ├─ summary()         ← counts
   │        └─ memories()        ← only if `bd prime` is NOT already a session hook
   │     else: print nothing (graceful)
   │
   ▼
Agent starts work
```

Two modes to decide at build time `[INFERRED]`:

- **AEGL-owns-injection** (recommended for v1.4): AEGL prints a compact "Work" section, and
  AEGL does **not** install Beads hooks. RuleSync's AGENTS block tells the agent it can run
  `bd prime` / `bd ready` itself.
- **Beads-owns-injection**: Beads hooks inject `bd prime`; then AEGL must **not** print
  memories (else duplication). AEGL prints only repo/session state.

The former keeps AEGL as the single injection owner and matches the RuleSync decision.

**Context budget:** `aegl resume` output is small; the Beads additions are bounded by
`--limit` on ready and, if memories are included, `--max-memories`/`--max-memory-chars`. On
our sample, `bd prime` full ≈ 826 words; `bd prime --memories-only` ≈ 16 lines. AEGL should
**not** concatenate the full `bd prime` (that text is workflow guidance the agent can fetch on
demand) — it should surface **ready work + memories only**. `[SANDBOX]` `[INFERRED]`

---

## Proposed Handoff Flow

`aegl handoff` must **not** write Beads on every call. Writing rules `[INFERRED]`:

```
aegl handoff [--goal ...] [--next ...] [--do-not-repeat ...]
   │
   ├─ always: write state.json + HANDOFF.md + NEXT-SESSION.md + history + event
   │
   ├─ read Beads (if enabled): build memory summary block (ready/open/blocked/currentTask)
   │        – read-only, cheap (`bd ready --json --limit 1`, `bd status`/counts)
   │
   ├─ DO NOT: create issues, close issues, or sync automatically
   │
   └─ optionally (explicit flags only):
        --remember "<durable fact>"   → adapter.remember(redacted)
        --forget <key>                → adapter.forget(key)
```

Never write: every shell command, every file edit, every test run. Only **current task /
status change / important decision / durable memory**, and only when explicitly requested.
This prevents "handoff spam" in the Beads DB. `[INFERRED]`

---

## Failure / Offline Behavior

Principle: **persistent memory must never make `aegl resume` unusable.** Graceful
degradation, always. `[SANDBOX]` `[INFERRED]`

| Failure | Observed Beads behavior | AEGL required behavior |
|---|---|---|
| `bd` not on PATH | n/a | `available()==False` → print one info line, continue |
| workspace not initialized | `bd prime` exits 0, empty | treat as "no work memory"; never error |
| `BEADS_DIR` parent missing | `bd init` aborts (`workspacegate: gate parent … must exist`) | AEGL pre-creates `.aegl/` before init |
| DB locked / embedded single-writer busy | commands can block or fail | subprocess **timeout**; skip section |
| Dolt server unavailable (server mode) | `Dolt server unreachable …` | not applicable in embedded default; still timeout+skip |
| schema mismatch (DB ahead) | actionable error, `BD_IGNORE_SCHEMA_SKEW=1` escape | surface a warning; do not attempt to migrate |
| remote offline | `No remote is configured — skipping.` **rc=0** | never gate on sync; sync stays user-driven |
| Beads DB corrupt | n/a | skip work-memory section; AEGL continuity still works |

Rule: every adapter call is wrapped in try/timeout and downgraded to a **warning**, exactly
like AEGL's existing best-effort CI collection.

---

## Security / Secrets

`[SOURCE]` `[SANDBOX]`

- **Local by default:** no remote is configured by default; `bd dolt push`/`bd sync` with no
  remote print "No remote is configured — skipping." and exit 0. Nothing left the machine in
  our sandbox.
- **Telemetry is ON by default** (opt-out): GA4-style transport to
  `https://gastownhall-eventsapi.com/mp/collect`; payload is limited to command name, app
  version, OS platform, and an HMAC machine id — **no issue text, paths, remotes, or identity**.
  Opt-outs: `bd metrics off`, `BD_DISABLE_METRICS`, `DO_NOT_TRACK` (disable-only).
  **AEGL must default these to disabled on invocations it controls, and document it.** `[SOURCE]`
- **Cross-machine sync is opt-in and, since v1.3.0, consent-gated** — `bd dolt push`/`bd sync`
  no longer silently adopt a git origin (previously could publish an entire issue DB to a
  public origin). `[SOURCE]`
- **`bd config list` and `GET /v0/beads/config` no longer enumerate the `kv.` plane** (i.e. no
  longer leak memories); an unauthenticated memory leak was closed in v1.3.0. `[SOURCE]`
- **Beads does no redaction.** Tokens/keys/prompts could be `bd remember`-ed verbatim.
  **AEGL must run `secrets.clean_text()` on all content before any `bd remember`.** Never
  `bd remember` raw command output or prompts.
- **Secrets are never stored in the Dolt DB** by Beads itself (tracker tokens live in YAML/env).
  AEGL's rule "secrets never enter persistent memory" already matches this. `[SOURCE]` `[INFERRED]`
- Additional AEGL boundary: do not enable a Dolt remote automatically; leave `bd dolt push`
  as an explicit user action.

---

## Performance

`[SANDBOX]` (single run, tiny embedded DB, warm-ish). Orders of magnitude only:

| Operation | Wall | Budget note |
|---|---|---|
| `bd --version` | 0.07 s | cheap capability probe |
| `bd prime` / `--memories-only` | ~0.19 s | fine per resume |
| `bd status` / `bd memories` | ~0.23 s | fine |
| `bd ready --json` | ~0.29 s | fine |
| `bd show` / `bd list --json` | ~0.44–0.46 s | use `--limit` |
| `bd remember` | ~0.29 s | only on explicit write |
| `bd create` | ~0.70 s | agent-driven |
| `bd init` | **5.3–5.5 s** | one-time; not on the resume path |

**Conclusion:** all read operations used on the resume path are well under 0.5 s on a tiny DB;
they are suitable for a per-resume call, but AEGL should batch them (one `ready` + one `status`),
apply `--limit`, and never call `bd` when the backend is disabled. The `bd` binary is large
(155 MB) and embedded Dolt startup dominates cold calls; AEGL must set subprocess timeouts
(e.g. 5 s) and degrade. No benchmark-grade measurement is claimed. `[INFERRED]`

---

## Version Pinning

`[SOURCE]` `[COMMUNITY]` `[INFERRED]`

Context: Beads ships a **schema-version guard** (DB ahead of binary → hard error), runs
migrations automatically on writable open (schema v69 in v1.3.1), had an accidental broken
release (v1.2.1 pulled) and cross-version migration incidents (#4176 p0, #4380 p1). There is
an open request (#3006) for repo-pinned versions, i.e. **Beads itself does not offer repo
pinning today**.

**Recommendation:**

- AEGL records an **exact tested version** (e.g. `bd 1.3.1`, commit `c1c4b642`) in its own
  metadata (`memory.beads.testedVersion`), and treats it as *"known-good"*, not *"required"*.
- Gate: if `bd --version` parses and is within **`>=1.3.0, <2.0.0`**, proceed. Outside that
  range → **warn and fall back to `none`** for the session, never error and never auto-migrate.
- **Never** let AEGL trigger a schema migration: AEGL does not run `bd migrate`. If a DB is
  ahead of the binary, surface the warning and skip.
- Do **not** hard-pin to a single patch (forces upgrades on the user and breaks the moment
  Beads moves); do **not** accept any version (schema skew is a real crash class). A
  compatible-range check + recorded tested version is the reproducibility/robustness balance.
- Because the **memory model is under active redesign** (#5877), isolate all memory access
  behind the adapter so a future format change is a one-file change in AEGL.

---

## Installation Strategy

`[OFFICIAL]` `[INFERRED]`

Beads' official stance is explicit: **install the CLI once, do not clone the repo into your
project.** Supported channels: Homebrew (`brew install beads`, recommended on macOS/Linux),
npm (`@beads/bd`), mise, install script (verify checksums), PowerShell (Windows), `go install`
(cgo for embedded-capable; nocgo = server-mode only), source (contributors).

**AEGL recommendation:**

- Provide `aegl memory setup beads` (design only in v1.4 planning) that:
  1. detects `bd` via `shutil.which`;
  2. if absent, prints the official install options (brew / npm / script / go install cgo)
     and stops — **AEGL does not auto-download a 53 MB tarball or vendor Beads**;
  3. if present, checks `bd --version` against the compatible range;
  4. `mkdir -p .aegl` (required by the workspace gate), then
     `BEADS_DIR=<repo>/.aegl/beads bd init --stealth -p <prefix> --skip-agents`;
  5. sets `memoryBackend: "beads"` in `.aegl/continuity/config.json` and adds `.aegl/beads/`
     to `.gitignore`.
- **Never** vendor Beads source, never add it as a submodule, never check the DB or binary into Git.
- Honest limitation to document: AEGL gets **no pinned-patch guarantee** from Beads today, so
  the adapter's compatible-range fallback is the reproducibility mechanism.

---

## Migration Strategy

`[INFERRED]`

Switching `memoryBackend: none → beads` must be **additive**:

- **Do not bulk-import** old `HANDOFF.md` / `history/` / `events.jsonl` into Beads. They are
  session-scoped narrative, not task graph; importing them would create noise issues.
- Start the Beads work graph **from the moment it is enabled** (empty DB is fine).
- Optional, explicitly user-triggered seeding: convert the current `next.action` into one task,
  and durable `doNotRepeat`/`importantDecisions` entries into a handful of `bd remember` keys.
  Even this should be a separate, opt-in command, not automatic.
- Keep AEGL's own history/events independent of Beads history: two histories, two purposes.

---

## Disable / Removal Strategy

`[INFERRED]`

- **Disable** = set `memoryBackend: "none"` (or `aegl memory disable beads`): AEGL stops calling
  `bd`, prints no work section, and **the Beads database is left untouched** (data preserved at
  `.aegl/beads/`). This must be trivially reversible.
- **Purge** = a separate, explicit, destructive command (`aegl memory purge beads`, requiring
  confirmation) that removes `.aegl/beads/` and the gate lock, and clears the config. Never the
  default of "disable".
- AEGL Continuity must remain fully functional after either operation — the `none` backend is
  the v1.3 baseline and stays the fallback.
- Document that removing `.aegl/beads/` loses the work graph unless the user has pushed a Dolt
  remote or run `bd export --all`.

---

## v1.4 MVP

Smallest useful slice — **5–8 capabilities**, all optional and fail-soft `[INFERRED]`:

1. **`bd` detection + version check** — `available()`, `version()`, compatible-range gate
   (`>=1.3.0,<2.0.0`), path via `shutil.which`.
2. **Workspace resolution** — adapter sets `BEADS_DIR=<root>/.aegl/beads` (config-driven),
   disables telemetry (`BD_DISABLE_METRICS=1 DO_NOT_TRACK=1`), and exposes `workspace()`.
3. **Init helper** — `aegl memory setup beads`: pre-create `.aegl/`, run
   `bd init --stealth --skip-agents -p <prefix>`, update config + `.gitignore`.
4. **`prime`/read** — `aegl resume` surfaces a compact **Ready work** list
   (`bd ready --json --limit N`) and counts, behind `memoryBackend == "beads"`.
5. **`remember`/`forget`** — `aegl memory remember "…" [--key k]` / `forget <key>`, with
   `secrets.clean_text()` applied first.
6. **`current task` reference** — record `currentTask` (the issue claimed by the actor) into
   `state.json`'s reference summary; never copy the graph.
7. **Graceful fallback** — every failure downgraded to a warning; `none` fallback guaranteed.
8. **`handoff` reference block** — `aegl handoff` writes a read-only `memory` summary
   (backend, version, ready/open/blocked/inProgress counts, currentTask) — no writes to Beads.

Explicitly **not** in the MVP: `aegl work ready/claim/close`, DAG features, multi-agent
scheduling, sync proxying, agent hook installation.

---

## Non-Goals

Explicitly **NOT v1.4** `[INFERRED]`:

- Multi-agent scheduler / orchestration.
- Direct Dolt access, custom Dolt implementation, or a Dolt server lifecycle manager.
- Re-implementing Beads (issues, DAG, ready queue, claiming) inside AEGL.
- Complex bidirectional sync (Beads DB → AEGL JSON → HANDOFF → Beads).
- Vendoring / submoduling Beads source or shipping its 155 MB binary.
- A knowledge-graph UI, web UI, or full issue-tracker UI.
- `bd setup <agent>` execution or Beads-owned AGENTS.md/CLAUDE.md/hooks.
- Message/mail, molecules/formulas, gates, federation, MCP server.
- Auto-migrating old AEGL session history into Beads.
- Changing `VERSION`, releasing, or tagging as part of this research.

---

## Risks

Ranked, with mitigations `[INFERRED]` (grounded in the evidence above):

**High**

| Risk | Why | Mitigation |
|---|---|---|
| Beads schema migration / skew | auto-migrations; DB-ahead hard error; incidents #4176 (p0), #4380 (p1), accidental v1.2.1 | never AEGL-triggered migration; version-range gate; `none` fallback; pin tested version |
| Agent-instruction conflict (RuleSync vs `bd init`/`setup`) | both write AGENTS.md/CLAUDE.md/.cursor; #5161, #5655; hardcoded imperative rules | RuleSync is sole owner; only `bd init --stealth --skip-agents`; never `bd setup` |
| Secret persistence into Beads memory | Beads does no redaction; `bd remember` is verbatim | AEGL redacts before every `bd remember`; never remember raw output/prompts |
| Two task systems / double source of truth | `state.json` vs Beads status | reference-only bridge; Beads owns task graph; AEGL owns session |

**Medium**

| Risk | Mitigation |
|---|---|
| Beads CLI breaking changes between minor versions | compatible-range gate; adapter isolation; recorded tested version |
| Dolt operational complexity (locks, single-writer embedded) | embedded default; subprocess timeouts; never manage the server |
| Hooks context duplication / startup cost | AEGL owns injection in v1.4; do not also install Beads hooks |
| Cross-machine memory expectations | document that AEGL continuity stays local; Beads remote sync is opt-in/user-driven |
| Telemetry default-on | AEGL forces `BD_DISABLE_METRICS`/`DO_NOT_TRACK` and documents it |
| `bd` binary size / install friction | detect + guide official install; never vendor |

**Low**

| Risk | Mitigation |
|---|---|
| `bd` absent | `available()` false → info line; continuity unaffected |
| Memory model redesign (#5877) | isolate memory access behind adapter; pin/range-check |
| `.git/info/exclude` mutation by stealth | git-internal, invisible; document it |
| `conditional-blocks` semantics bug (#5577) | AEGL does not depend on conditional semantics in v1.4 |

---

## Community Findings

Surveyed 7,095 open issues; 9 themes relevant to AEGL `[COMMUNITY]`:

1. **Setup invasiveness / duplicate AGENTS.md blocks** — #5161 (duplicate `## Beads Issue
   Tracker` from `bd setup codex` over an existing managed block), #5655 (`bd init` scaffolds
   every tool with no detection), #5169 (hardcoded, unconfigurable anti-`MEMORY.md` rule).
   → Confirms AEGL must own agent rules and avoid `bd init`/`setup` defaults.
2. **Dolt server reliability** — #2559 (18 comments: server unreachable after restart/upgrade),
   #3392 (auto-start races + stale locks). → Embedded default avoids the server; still timeout.
3. **Migration / corruption** — #4176 (fresh clone crashes in migration `0047`, p0), #4380
   (migration pass panics on drifted storage, 27 comments, p1), #4251 (per-commit auto-GC:
   ~15 s writes + corruption risk, p1). → Never let AEGL drive migrations; pin and fall back.
4. **Version pinning** — #3006 (repo-pinned Beads versions, 2 reactions). → Beads has no
   repo-pinning today; AEGL must range-check itself.
5. **Release/tag drift** — #3924 (`bd codex-hook` missing from the v1.0.4 binary while present
   on main), #4469/#4848 (requests to cut a release from main). → Prefer released tags; avoid
   depending on unreleased subcommands.
6. **Storage-model debate** — #4404 (one file per issue instead of Dolt). → Storage may evolve;
   don't couple to Dolt internals.
7. **Memory-model redesign** — #5877 "Proposal: Memory Beads" (112 comments, Rev 4:
   memories become first-class entities with keys resolving to canonical IDs). → Isolate memory
   access; expect the `bd remember` surface to change.
8. **Semantics bugs** — #5577 (`conditional-blocks` unblocks on any close). → Don't use
   conditional-blocks in v1.4.
9. **Sync integration requests** — #5643 (GitHub sync via `gh`/`glab`, OAuth). → Tracking
   integrations are third-party/optional; out of scope.

Not used as decision input: stars/forks/popularity (recorded for context only).

---

## Recommendation

**Recommended Architecture: Option B — "AEGL calls Beads CLI as an OPTIONAL persistent memory /
long-horizon work-graph backend," combined with Option E ("agents may use `bd` directly") for
work-lifecycle operations AEGL does not wrap.**

Layout:

```
AEGL Continuity  ──owns──▶  Session state (git/HEAD/VERSION/CI/handoff/resume/events/history)
                              │
                              └── reads (reference only) ──▶  PersistentMemoryBackend = beads
                                                                     │
                                                                     └── subprocess ──▶ bd CLI
                                                                                        │
                                                                        Beads (Dolt, in .aegl/beads)
                                                                          • tasks + dependencies + blockers
                                                                          • durable memories
                                                                          • multi-agent claims (later)
```

- **AEGL owns session continuity.** **Beads owns the long-horizon work graph.** No canonical
  data is duplicated.
- **Integration is via the `bd` CLI only** — never the Dolt DB, never the Go module.
- **Isolation primitive:** `BEADS_DIR=<repo>/.aegl/beads` + `bd init --stealth --skip-agents`
  (AEGL pre-creates `.aegl/`). This honors AEGL's non-invasive principle.
- **Agent rules stay owned by RuleSync.** AEGL emits one guidance line about `bd`; it never
  runs `bd setup`.
- **Optional and fail-soft:** `memoryBackend` defaults to `none`; any Beads failure degrades to
  a warning and continuity keeps working.

### Direct answers

**Should AEGL integrate Beads?** — **YES.** It fills exactly the gap v1.3 leaves (long-horizon
tasks, dependencies, durable memory) and the v1.3 codebase already reserved a backend seam for it.

**Should Beads be mandatory?** — **NO.** "Optional" preserves the v1.3 baseline and avoids coupling
AEGL's core (and its CI/reproducibility) to a fast-moving external schema and CLI.

**Should AEGL vendor Beads?** — **NO.** Beads officially says install the CLI once and don't clone
it into the project; a 155 MB binary and an Apache-2.0 Dolt payload do not belong in AEGL.

**Should AEGL use bd CLI?** — **YES.** It is the only stable, documented, agent-facing contract;
it keeps AEGL decoupled from Dolt and lets Beads evolve internally.

**Should AEGL directly access Dolt DB?** — **NO.** Dolt is a Beads implementation detail; direct
access would couple AEGL to schema migrations it must never trigger.

**Should Beads replace AEGL Continuity?** — **NO.** Beads has no notion of git HEAD, dirty tree,
CI, VERSION, deterministic resume, or secret-redacted handoff; those are AEGL's purpose.

**Should Beads own long-horizon task graph?** — **YES.** Its dependency DAG and ready queue are
mature and empirically correct; AEGL must not re-implement them.

**Should AEGL keep HANDOFF/resume?** — **YES.** They are the session-continuity contract and the
fallback when Beads is absent; they remain canonical for session state.

**Should Beads agent setup manage AGENTS.md?** — **NO.** It directly collides with RuleSync and
carries imperative rules AEGL does not want; AEGL initializes Beads with `--stealth --skip-agents`.

**Should RuleSync remain owner of agent rules?** — **YES.** Single source of truth for agent
instructions; Beads rules, if any, are referenced from RuleSync's output, never injected by Beads.

### Options considered

| Option | Verdict |
|---|---|
| A. No integration | Rejected — leaves a documented v1.3 gap unfilled. |
| **B. Optional CLI backend** | **Recommended.** |
| C. Mandatory core dependency | Rejected — couples AEGL to Beads' migration/CLI risk and breaks the `none` baseline. |
| D. Vendor / embed | Rejected — against Beads' own guidance; bloats AEGL; license/maintenance burden. |
| E. Agent-level only (no bridge) | Partially adopted — agents may use `bd` directly for lifecycle; AEGL still adds a thin read/remember bridge. |

---

## Proposed v1.4 Build Plan

Design only — **do not implement in this task.** Suggested shape for the follow-up PR:

**Phase 0 — decisions locked**
- Adopt Option B + E; RuleSync stays sole agent-rule owner; `BEADS_DIR=.aegl/beads` isolation.

**Phase 1 — adapter skeleton (no behavior change)**
- `adapters/memory/beads/adapter.py` + `adapter.json` (mirroring the existing `adapters/<lang>/`
  convention), implementing `BeadsMemoryBackend` (`available/version/workspace/ready/summary/
  current_work/memories/remember/forget`).
- `core/continuity/memory.py`: turn `load_backend` into a registry
  (`none`, `beads`), unknown → `none`. Keep the base class API stable.
- Every `bd` call: `--json` where available, fixed timeout, `BD_DISABLE_METRICS=1`,
  `DO_NOT_TRACK=1`, `BEADS_DIR` from config; errors → `None`.

**Phase 2 — config + setup**
- `config.json`: add `memoryBackend`, `beads{dir, prefix, testedVersion, readyLimit,
  maxMemories, telemetry:"disabled"}`.
- `aegl memory setup beads|status|disable|purge` (setup pre-creates `.aegl/`, runs
  `bd init --stealth --skip-agents -p <prefix>`; disable ≠ purge).

**Phase 3 — resume/status integration**
- `aegl resume`/`status`: if backend enabled and available, add a bounded **Ready work** section
  (`bd ready --json --limit N`) and a `memory` reference block; never print full `bd prime`.
- `state.json`: add the reference-only `memory` block to the schema + renderers.

**Phase 4 — handoff integration**
- `aegl handoff`: write the reference block; add explicit `--remember/--forget` only.

**Phase 5 — safety & tests**
- Redaction-before-remember test; `bd`-absent fallback test; version-range gate test;
  subprocess-timeout test; "no AGENTS.md contention" test (assert AEGL never writes
  `<!-- BEGIN BEADS INTEGRATION`).
- Extend `scripts/continuity-smoke.py`; add a CI job that installs a pinned `bd` and exercises
  the adapter against `BEADS_DIR` in a throwaway git repo (**CI stays green without Beads** via
  the `none` fallback).

**Phase 6 — docs**
- README section: "AEGL v1.4 Persistent Work Memory (Beads, optional)"; document the telemetry
  default, the isolation layout, compatible-version range, and disable/purge semantics.

**Explicit stop condition for this task:** research + sandbox + report only. No adapter code,
no changes to `core/continuity/memory.py`, no `adapters/memory/beads/`, no `VERSION` change,
no tag/release/branch.

---

## Appendix — AEGL v1.3 `PersistentMemoryBackend` (verbatim)

```python
# core/continuity/memory.py @ v1.3.0
"""Reserved pluggable persistent-memory backend (build plan §18).
v1.3 ships only the ``none`` backend ... A real ``beads`` backend is deliberately
deferred to v1.4 so this release's scope does not grow.
"""
class PersistentMemoryBackend:
    """Interface a future backend (e.g. Beads) must implement."""
    name = "none"
    def available(self) -> bool:
        return False
    def store(self, root: Path, snapshot: dict) -> None:
        """Persist a handoff snapshot. The default backend is a no-op."""
    def query(self, root: Path) -> list[dict]:
        """Return previously persisted snapshots. The default returns none."""
        return []

class NoneBackend(PersistentMemoryBackend):
    name = "none"

def load_backend(config: dict | None) -> PersistentMemoryBackend:
    requested = (config or {}).get("memoryBackend", "none")
    # Only "none" exists in v1.3; unknown requests fall back to none rather than
    # failing, and "beads" is documented as the v1.4 target.
    return NoneBackend()
```

Single call site: `core/continuity/commands.py` → `do_handoff`:
`memory.load_backend(cfg).store(root, snapshot)`. `available()` and `query()` are currently
unused; there is no registry or `adapters/memory/` directory yet. `[SOURCE]`
