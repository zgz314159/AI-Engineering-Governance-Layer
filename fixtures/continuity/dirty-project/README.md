# Continuity fixture: dirty-project

Scenario: a handoff records a clean working tree, then tracked files are
modified without committing. `aegl resume` must emit a dirty WARNING.
