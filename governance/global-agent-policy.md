---
targets:
  - "*"
root: true
description: "Global AI development boundary; project-specific rules remain in each project."
---

# AI development boundary

- Treat formal project checkouts as read-only while doing AI-assisted work. Make changes in an approved disposable worktree outside the formal project, then use the trusted promotion path.
- Keep authoritative source, test source, fixtures, schemas, locks, build scripts, and project-specific policy in the owning project. Do not make a project depend on undeclared source under a tool installation or another project.
- Keep generated builds, test results, caches, logs, screenshots, APKs, temporary databases, and task state out of formal project trees and out of the Projects directory. Dispose of completed task outputs rather than retaining archives.
- Do not bypass a failed path, sandbox, or promotion gate. Report the exact blocker; do not claim completion from a partial test.
- Never overwrite an existing agent instruction file as part of rule synchronization without an explicit conflict resolution.
