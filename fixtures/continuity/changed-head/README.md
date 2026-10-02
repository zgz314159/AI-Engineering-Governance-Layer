# Continuity fixture: changed-head

Scenario: a handoff is written, then a new commit appears before the next
session. `aegl resume` must report HANDOFF STALE (a warning, not a block).
