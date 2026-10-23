# Guard pin artifact

Bytes of `contract_guard.py` at Stack commit declared in `recovery/guard-lock.json`.
`install-model-broker.sh` extracts from the Stack repo when the pin commit is present;
if that object is missing (GC / shallow), it falls back to this AEGL-committed artifact
and still verifies the lock sha256. Never substitute a live Stack worktree file.
