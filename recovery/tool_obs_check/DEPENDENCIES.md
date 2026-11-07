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
