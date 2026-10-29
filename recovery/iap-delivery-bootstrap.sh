#!/usr/bin/env bash
# Copy this script to a root-private directory and verify its separately supplied
# SHA256 BEFORE executing it. It then establishes the complete package anchor.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'BOOTSTRAP_FAILED=need_root' >&2; exit 1; }
SRC=''; ANCHOR=''
while (($#)); do
  case "$1" in
    --src) SRC=${2:?}; shift 2 ;;
    --manifest-sha256) ANCHOR=${2:?}; shift 2 ;;
    *) echo "BOOTSTRAP_FAILED=unknown_argument" >&2; exit 1 ;;
  esac
done
[[ -n $SRC && $ANCHOR =~ ^[0-9a-f]{64}$ ]] || { echo 'BOOTSTRAP_FAILED=arguments' >&2; exit 1; }
DEST=$(mktemp -d /root/iap-delivery.XXXXXX)
chmod 0700 "$DEST"
echo "PACKAGE_DIR=$DEST"
# This is system Python, with only literal bootstrap code; no package code executes
# until the externally anchored manifest and every copied file have been checked.
python3 -I - "$SRC" "$DEST" "$ANCHOR" <<'PY'
import hashlib, os, re, shutil, stat, sys
from pathlib import Path, PurePosixPath
src, dst, anchor = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
def need(ok, why):
    if not ok: raise SystemExit('BOOTSTRAP_FAILED=' + why)
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1048576), b''): h.update(b)
    return h.hexdigest()
need(not src.is_symlink() and src.is_dir(), 'source')
need(not (src/'MANIFEST.sha256').is_symlink(), 'manifest_symlink')
shutil.copyfile(src/'MANIFEST.sha256', dst/'MANIFEST.sha256')
os.chmod(dst/'MANIFEST.sha256', 0o600)
need(sha(dst/'MANIFEST.sha256') == anchor, 'package_anchor')
seen=set(); entries={}
for line in (dst/'MANIFEST.sha256').read_text().splitlines():
    m=re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_./-]+)', line)
    need(m is not None, 'manifest_line')
    want, rel=m.groups(); p=PurePosixPath(rel)
    need(not p.is_absolute() and '..' not in p.parts and str(p)==rel and rel not in seen, 'manifest_path')
    seen.add(rel); entries[rel]=want; source=src
    for part in p.parts:
        source=source/part; need(not source.is_symlink(), 'source_symlink')
    need(source.is_file(), 'source_file')
    target=dst/rel; parent=dst
    # pathlib parents=True uses default permissions for intermediate parents.
    # Create each level explicitly so payload/aegl stays private even with umask 022.
    for part in p.parts[:-1]:
        parent=parent/part; parent.mkdir(mode=0o700, exist_ok=True)
        need(not parent.is_symlink() and stat.S_IMODE(parent.stat().st_mode)==0o700, 'destination_directory')
    shutil.copyfile(source, target); os.chmod(target, 0o600)
    need(sha(target)==want, 'copied_payload_hash')
need({'iap_delivery.py','release.json','install-model-task-registry.sh'} <= seen, 'missing_entrypoints')
for rel,want in entries.items(): need(sha(dst/rel)==want, 'final_hash')
print('BOOTSTRAP_VERIFIED files=' + str(len(seen)), flush=True)
PY
set +e
PYTHONDONTWRITEBYTECODE=1 python3 -I "$DEST/iap_delivery.py" \
  --package "$DEST" --package-anchor "$ANCHOR"
rc=$?
set -e
if ((rc != 0)); then
  echo "PACKAGE_RETAINED=$DEST"
  echo "DELIVERY_EXIT_CODE=$rc"
  exit "$rc"
fi
# Success cleanup uses exactly the verified members. Unexpected files stop cleanup.
python3 -I - "$DEST" "$ANCHOR" <<'PY'
import hashlib, sys
from pathlib import Path
p=Path(sys.argv[1]); manifest=p/'MANIFEST.sha256'
if hashlib.sha256(manifest.read_bytes()).hexdigest()!=sys.argv[2]: raise SystemExit('CLEANUP_FAILED=manifest_changed')
dirs=set()
for line in manifest.read_text().splitlines():
    sha,rel=line.split('  ',1); f=p/rel
    if hashlib.sha256(f.read_bytes()).hexdigest()!=sha: raise SystemExit('CLEANUP_FAILED=payload_changed')
    parent=f.parent
    while parent!=p: dirs.add(parent); parent=parent.parent
for line in manifest.read_text().splitlines(): (p/line.split('  ',1)[1]).unlink()
manifest.unlink()
for d in sorted(dirs,key=lambda x:len(x.parts),reverse=True): d.rmdir()
p.rmdir()
print('PACKAGE_CLEANUP=OK')
PY
echo 'DELIVERY_EXIT_CODE=0'
