#!/usr/bin/env bash
# Linux compat entry for scripts/10-fetch-upstreams.ps1
# Same core logic: pin the 6 upstream repos at the refs in versions.json and
# write upstream-lock.json with the resolved commit SHAs.
#
# Linux-specific hardening: the link to GitHub intermittently drops large TLS
# fetches ("GnuTLS recv error"), so clones are shallow and retried, and the
# HTTP transport is pinned to HTTP/1.1 with a large post buffer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

json_get() {
    python3 - "$1" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d=d[k]
print(d)
PY
}

if [ ! -d .git ]; then
    git init -q
    git branch -M main
fi
git config --local http.version HTTP/1.1
git config --local http.postBuffer 524288000

mkdir -p upstream

ITEMS=(spec-kit architecture-guard konsist detekt rulesync gradle-actions)
KEYS=(specKit architectureGuard konsist detekt ruleSync gradleActions)

for i in "${!ITEMS[@]}"; do
    name="${ITEMS[$i]}"
    key="${KEYS[$i]}"
    repo="$(json_get versions.json "$key.repo")"
    ref="$(json_get versions.json "$key.ref")"
    path="upstream/$name"

    if [ ! -f "$path/.git" ] && [ ! -d "$path/.git" ]; then
        rm -rf "$path"
        echo "[ADD] $name <- $repo @ $ref"
        ok=0
        for attempt in 1 2 3 4 5; do
            if git submodule add --depth 1 "$repo" "$path"; then ok=1; break; fi
            echo "[RETRY $attempt] $name clone failed; retrying"
            git submodule deinit -f "$path" 2>/dev/null || true
            rm -rf "$path"
            sleep 3
        done
        [ "$ok" -eq 1 ] || { echo "ERROR: could not clone $name" >&2; exit 1; }
    else
        echo "[EXISTS] $path"
        git submodule update --init --recursive -- "$path"
    fi

    # If the submodule already sits at the commit recorded in the superproject
    # gitlink, it is already pinned — skip network fetch/checkout. This is the
    # normal case in CI (actions/checkout checks submodules out at the pinned
    # commit but without the tag objects, so `checkout <tag>` would fail).
    recorded="$(git ls-tree HEAD -- "$path" 2>/dev/null | awk '{print $3}')"
    current="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$recorded" ] && [ "$recorded" = "$current" ]; then
        echo "[PINNED] $name @ $current"
        continue
    fi

    # Resolve the pinned ref (tag or branch) with a shallow fetch.
    if [ -d "$path/.git" ]; then
        git -C "$path" fetch --depth 1 origin "refs/tags/$ref:refs/tags/$ref" 2>/dev/null \
            || git -C "$path" fetch --depth 1 origin "$ref" 2>/dev/null \
            || git -C "$path" fetch --tags --force
    fi
    git -C "$path" checkout --detach "$ref"
done

git add .gitmodules upstream

python3 - "$ROOT" <<'PY'
import json, subprocess, sys, collections
root=sys.argv[1]
items=[("spec-kit","specKit"),("architecture-guard","architectureGuard"),
       ("konsist","konsist"),("detekt","detekt"),
       ("rulesync","ruleSync"),("gradle-actions","gradleActions")]
versions=json.load(open(f"{root}/versions.json"))
lock=collections.OrderedDict()
for name,key in items:
    sha=subprocess.check_output(["git","-C",f"{root}/upstream/{name}","rev-parse","HEAD"],text=True).strip()
    lock[name]=collections.OrderedDict([("ref",versions[key]["ref"]),("commit",sha),("repo",versions[key]["repo"])])
open(f"{root}/upstream-lock.json","w").write(json.dumps(lock,indent=2)+"\n")
print("[OK] Wrote upstream-lock.json")
PY

echo "FETCH: PASS"
