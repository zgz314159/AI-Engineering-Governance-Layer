#!/usr/bin/env bash
# iap-cleanup-bootstrap.sh — trusted bootstrap for the cleanup-only package (root only).
#
# The operator copies THIS file into a fresh root-owned 0700 directory and verifies its
# standalone SHA256 BEFORE running it. It then:
#   1. copies ONLY MANIFEST.sha256 into a new root-exclusive destination;
#   2. compares it to the fixed SHA256 supplied by the operator (the trust anchor);
#   3. copies every listed file, fixing owner/mode; 4. verifies; 5. exec bin/cleanup.sh.
# The whole package is never copied with cp -a, and the package's own hash file is not
# the sole trust anchor.
set -euo pipefail

SRC=""; DEST=""; ANCHOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="${2:-}"; shift 2 ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    --manifest-sha256) ANCHOR="${2:-}"; shift 2 ;;
    *) printf 'BOOTSTRAP_FAILED reason=usage: unknown argument %s\n' "$1" >&2; exit 1 ;;
  esac
done
fail() { printf 'BOOTSTRAP_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail not_root "bootstrap must run as root"
[ -n "$SRC" ] && [ -d "$SRC" ] || fail src_missing "$SRC"
[ ! -L "$SRC" ] || fail src_symlink "$SRC"
[ -n "$DEST" ] || fail usage "--dest is required"
[ "${#ANCHOR}" -eq 64 ] || fail usage "--manifest-sha256 <64-hex> is required"
case "$ANCHOR" in *[!0-9a-f]*) fail usage "anchor must be lowercase 64-hex" ;; esac
[ ! -e "$DEST" ] || fail dest_exists "$DEST (refusing to reuse an existing directory)"

install -d -o root -g root -m 0700 "$DEST"
install -o root -g root -m 0600 "$SRC/MANIFEST.sha256" "$DEST/MANIFEST.sha256"
GOT="$(sha256sum "$DEST/MANIFEST.sha256" | awk '{print $1}')"
[ "$GOT" = "$ANCHOR" ] || fail manifest_anchor_mismatch "manifest=$GOT anchor=$ANCHOR"

while read -r sha rel; do
  [ -n "$rel" ] || continue
  case "$rel" in /*|*..*) fail bad_path "$rel" ;; esac
  [ -f "$SRC/$rel" ] && [ ! -L "$SRC/$rel" ] || fail payload_file_missing "$rel"
  install -d -o root -g root -m 0755 "$DEST/$(dirname "$rel")"
  case "$rel" in bin/*|*.sh) mode=0755 ;; *) mode=0644 ;; esac
  install -o root -g root -m "$mode" "$SRC/$rel" "$DEST/$rel"
done < "$DEST/MANIFEST.sha256"
printf '%s\n' "$GOT" > "$DEST/MANIFEST.sha256.sha256"
( cd "$DEST" && sha256sum -c --quiet MANIFEST.sha256 ) || fail copied_tree_hash "a copied file fails the manifest"

exec "$DEST/bin/cleanup.sh"
