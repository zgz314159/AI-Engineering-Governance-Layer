#!/usr/bin/env bash
# cleanup-iap-candidates.sh — precise, resumable cleanup of IAP delivery candidates.
#
# Root only. Removes ONLY the named attempt's candidate worktrees, temp refs, ledger and
# (optionally) root-owned package/bootstrap copies. No `rm -rf`, no global
# `git worktree prune`, no backup/archive, no registry edit.
#
# Why a broker-side `git worktree remove` fails:
#   the attempt root (/var/tmp/aegl-iap-<id>) is root:aegl-broker 0750. aegl-promote is in
#   aegl-broker, so it can TRAVERSE but not WRITE that directory -> deleting the candidate
#   child returns EACCES. Removal must therefore run as root (which may), never by
#   relaxing the staging or formal-tree permissions.
#
# This file is sourceable (main is guarded) so the classifiers can be flow-tested offline.

CLI_NAME="cleanup-iap-candidates"

say()  { printf '%s\n' "$*"; }
die()  {
  FAIL_REPORTED=1
  # visible to the parent even when die runs inside a command substitution
  if [ -n "${CLEANUP_FAIL_MARK:-}" ]; then : > "$CLEANUP_FAIL_MARK" 2>/dev/null || :; fi
  printf 'CLEANUP_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2
  exit 1
}

# git with exact, command-scoped trust for one path (never a wildcard)
git_safe() { local d="$1"; shift; git -c "safe.directory=$d" -C "$d" "$@"; }

# --- pure classifiers -------------------------------------------------------------- #
dir_state() { # <path> -> MISSING | EMPTY | NONEMPTY
  local p="$1"
  if [ ! -e "$p" ]; then printf 'MISSING'; return 0; fi
  if [ ! -d "$p" ]; then printf 'NOT_A_DIR'; return 0; fi
  if [ -z "$(ls -A "$p" 2>/dev/null)" ]; then printf 'EMPTY'; else printf 'NONEMPTY'; fi
}

wt_admin_present() { # <repo> <name> -> 0 present
  [ -d "$1/.git/worktrees/$2" ]
}

worktree_state() { # <repo> <name> <candidate> -> state
  #   MISSING_REGISTERED   : admin entry present, candidate dir gone
  #   EMPTY_REGISTERED     : admin entry present, candidate dir empty
  #   CLEAN_REGISTERED     : admin entry present, candidate is a clean worktree
  #   DIRTY_REGISTERED     : admin entry present, candidate has real modifications
  #   RESIDUE_UNREGISTERED : candidate present but no admin entry (or not a worktree)
  #   ABSENT / EMPTY_UNREGISTERED
  local repo="$1" name="$2" cand="$3" ds
  ds="$(dir_state "$cand")"
  if wt_admin_present "$repo" "$name"; then
    case "$ds" in
      MISSING|EMPTY) printf '%s_REGISTERED' "$ds" ;;
      NONEMPTY)
        if git_safe "$cand" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
           && [ -z "$(git_safe "$cand" status --porcelain 2>/dev/null)" ]; then
          printf 'CLEAN_REGISTERED'
        else
          printf 'DIRTY_REGISTERED'
        fi ;;
      *) printf 'RESIDUE_UNREGISTERED' ;;
    esac
  else
    case "$ds" in
      MISSING) printf 'ABSENT' ;;
      EMPTY)   printf 'EMPTY_UNREGISTERED' ;;
      *)       printf 'RESIDUE_UNREGISTERED' ;;
    esac
  fi
}

plan_action() { # <state> -> REMOVE_WORKTREE | DROP_ADMIN_ENTRY | DELETE_EMPTY_DIR | REFUSE_DIRTY | REFUSE_RESIDUE | NOTHING
  case "$1" in
    CLEAN_REGISTERED)     printf 'REMOVE_WORKTREE' ;;
    MISSING_REGISTERED)   printf 'DROP_ADMIN_ENTRY' ;;
    EMPTY_REGISTERED)     printf 'DROP_ADMIN_ENTRY' ;;
    EMPTY_UNREGISTERED)   printf 'DELETE_EMPTY_DIR' ;;
    DIRTY_REGISTERED)     printf 'REFUSE_DIRTY' ;;
    RESIDUE_UNREGISTERED) printf 'REFUSE_RESIDUE' ;;
    ABSENT)               printf 'NOTHING' ;;
    *)                    printf 'REFUSE_RESIDUE' ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  printf 'ERROR: %s is a helper library; use bin/cleanup.sh\n' "$CLI_NAME" >&2
  exit 2
fi
