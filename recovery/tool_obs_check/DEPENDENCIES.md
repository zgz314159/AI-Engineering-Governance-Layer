# Check-package runtime dependencies

## bin/guard_capture.py

- source: `/var/tmp/IAP-CONTROL-DEV/aegl/recovery/guard_capture.py`
- owning candidate: `926c34fbecf1157c2ae88e57e85ef67f6f82de33` (unchanged)
- sha256: `4422f725fc2fb88ecff4de6baba81a519e4f450be5ad644948b29745d877be1a`
- role: `model_broker._handle_guard` imports `guard_capture` from its own directory.
  The package ships an unmodified copy in `bin/`; it is included in
  `MANIFEST.sha256`, `VIEW_FILES`, the normal view and the observer-failure view.
  The broker must resolve it from that view only: there is no installed-tree, source
  repo or `PYTHONPATH` fallback, and `check_dependencies` proves the isolated
  `_handle_guard` import fails when the file is deliberately absent.

## bin/guard/contract_guard.py

- source: `/usr/local/lib/aegl-model/guard/contract_guard.py` (read-only installed copy)
- source sha256: `19f6be638c37b28d401820b7a4562f852a459188cbfa793f757668fe9b330455`
- frozen check input sha256: `19f6be638c37b28d401820b7a4562f852a459188cbfa793f757668fe9b330455`
- role: the guard used by the check package. The preflight hook command and both the
  normal view and the observer-failure view use this one packaged copy in
  `bin/guard/`; it is included in `MANIFEST.sha256` and `VIEW_FILES`. The installed
  file is copied read-only at package build time and is never modified, promoted or
  resolved at runtime from the install tree. `check_dependencies` pins the frozen
  copy's SHA-256. This aligns the check package with the current installed guard while
  keeping the candidate's four observation files unchanged: no runtime install-dir
  fallback is added.
