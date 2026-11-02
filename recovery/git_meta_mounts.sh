#!/usr/bin/env bash
# git_meta_mounts.sh — map a task worktree's Git metadata into the sandbox.
# Root only. Prints bwrap mount specs (kind:src:dest), one per line:
#   ro-bind:<common-dir>:<common-dir>     approved shared metadata, READ-ONLY
#   bind:<admin-view>:<worktree-gitdir>   THIS task's worktree admin, writable VIEW
# The host admin dir is never written; the view dies with the task dir.
#
# The paths are decided by REAL Git plus the trusted registration — never by the raw
# gitfile text: the worktree must be registered for the repo, the admin dir must be a
# direct worktrees/ child of that repo's .git, the backlink must agree, and the metadata
# must belong to the repo owner (never the sandbox identity).
#
# Usage: git_meta_mounts.sh <worktree> <admin-view-dir> <registered-repo> [--baseline]
# --baseline is diagnostic-only: it reproduces the pre-fix mount set (no Git metadata).
set -euo pipefail

WT="${1:?worktree}"; VIEW="${2:?admin view}"; REPO="${3:?registered repo}"; MODE="${4:-}"
AI_USER="${AEGL_AI_USER:-aegl-ai}"; AI_GROUP="${AEGL_AI_GROUP:-$AI_USER}"
die() { printf 'GIT_META_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die not_root "run as root"
[ "$MODE" = "--baseline" ] && exit 0
[ -e "$WT/.git" ] || exit 0                       # not a Git worktree: nothing to map

REAL_WT="$(realpath -e "$WT")" || die worktree "$WT"
REAL_REPO="$(realpath -e "$REPO")" || die repo "$REPO"
TRUST=(-c "safe.directory=$REAL_WT" -c "safe.directory=$REAL_REPO")
# every Git call keeps its REAL rc and its raw (bounded) stderr — nothing is discarded
rc=0
COMMON="$(git "${TRUST[@]}" -C "$REAL_WT" rev-parse --git-common-dir 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || die rev_parse_common "rc=$rc $(printf '%s' "$COMMON" | head -c 400 | tr '\n' ' ')"
[ "${COMMON#/}" != "$COMMON" ] || COMMON="$REAL_WT/$COMMON"
rc=0
GITDIR="$(git "${TRUST[@]}" -C "$REAL_WT" rev-parse --absolute-git-dir 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || die rev_parse_gitdir "rc=$rc $(printf '%s' "$GITDIR" | head -c 400 | tr '\n' ' ')"
COMMON="$(realpath -e "$COMMON")" || die common_missing "$COMMON"
GITDIR="$(realpath -e "$GITDIR")" || die gitdir_missing "$GITDIR"

# 1. the shared metadata must be the registered repo's own .git
[ "$COMMON" = "$REAL_REPO/.git" ] || die common_not_repo_git "$COMMON != $REAL_REPO/.git"
# 2. the admin dir must be a direct child of that .git/worktrees
case "$GITDIR" in "$COMMON/worktrees/"*) : ;; *) die gitdir_outside "$GITDIR" ;; esac
[ "$(dirname "$GITDIR")" = "$COMMON/worktrees" ] || die gitdir_nested "$GITDIR"
# 3. registration must agree in both directions
[ "$(cat "$GITDIR/gitdir" 2>/dev/null)" = "$WT/.git" ] \
  || die gitdir_backlink "$(cat "$GITDIR/gitdir" 2>/dev/null)"
WL="$(git "${TRUST[@]}" -C "$REAL_REPO" worktree list --porcelain 2>&1)" \
  || die worktree_list "rc=$? $(printf '%s' "$WL" | head -c 400 | tr '\n' ' ')"
printf '%s\n' "$WL" | grep -qxF -- "worktree $REAL_WT" || die not_registered "$REAL_WT"
# 4. ownership: the shared metadata belongs to the repo owner; the admin dir may be
#    root-owned (the trusted side creates worktrees) but must NEVER be the sandbox identity.
COMMON_OWNER="$(stat -c '%U' "$COMMON")"
[ "$COMMON_OWNER" = "$(stat -c '%U' "$REAL_REPO")" ] || die owner_mismatch "$COMMON is $COMMON_OWNER"
[ "$(stat -c '%U' "$GITDIR")" != "$AI_USER" ] || die owner_is_ai "$GITDIR is $AI_USER"
[ "$COMMON_OWNER" != "$AI_USER" ] || die owner_is_ai "$COMMON is $AI_USER"

# 5. per-task WRITABLE view of ONLY this worktree's admin dir — always a FRESH directory
[ ! -e "$VIEW" ] || die view_exists "$VIEW already exists (refusing to overwrite)"
mkdir -m 0700 -- "$VIEW" || die view_create "$VIEW"
cp -a "$GITDIR/." "$VIEW/" || die view_copy "$GITDIR"
chown -R "$AI_USER:$AI_GROUP" "$VIEW" || die view_chown "$VIEW"

printf 'ro-bind:%s:%s\n' "$COMMON" "$COMMON"
printf 'bind:%s:%s\n' "$VIEW" "$GITDIR"
