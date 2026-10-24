#!/usr/bin/env python3
"""Root-only trusted Hermes task registry.

Production registry (fixed):
    /var/lib/aegl-model/registry.json

Format (the launcher already reads this exact shape):
    task_id -> {worktree, scratch, project, contract_package}

This module only registers and queries. It does not launch, schedule, promote,
create projects, or grant permissions.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import pwd
import re
import stat
import sys
import tempfile

PRODUCTION_REGISTRY = "/var/lib/aegl-model/registry.json"
AI_USER = "aegl-ai"
ALLOWED_BASES = ("/tmp/", "/var/tmp/", "/run/aegl-", "/var/lib/aegl-")
TASK_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
ENTRY_FIELDS = ("worktree", "scratch", "project", "contract_package")

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_VALIDATION = 3
EXIT_REGISTRY = 4
EXIT_DURABILITY = 5
EXIT_IO = 6
EXIT_NOT_FOUND = 7


class RegistryError(Exception):
    exit_code = EXIT_IO

    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason
        self.message = message


class ValidationError(RegistryError):
    exit_code = EXIT_VALIDATION


class RegistryInvalid(RegistryError):
    exit_code = EXIT_REGISTRY


class DurabilityError(RegistryError):
    exit_code = EXIT_DURABILITY


class NotFoundError(RegistryError):
    exit_code = EXIT_NOT_FOUND


def _reject(reason: str, message: str) -> None:
    raise ValidationError(reason, message)


def validate_task_id(task_id: str) -> str:
    if not isinstance(task_id, str) or not TASK_ID_RE.fullmatch(task_id):
        _reject("invalid_task_id", "task_id must match [A-Za-z0-9._-]{1,64}")
    return task_id


def _real_existing_dir(path: str, label: str) -> str:
    if not isinstance(path, str) or not path or not os.path.isabs(path):
        _reject("invalid_path", "%s must be an absolute path" % label)
    if os.path.islink(path):
        _reject("symlink_path", "%s must not be a symlink" % label)
    try:
        real = os.path.realpath(path, strict=True)
    except OSError:
        _reject("missing_path", "%s does not exist" % label)
    if not os.path.isdir(real):
        _reject("not_a_directory", "%s is not a directory" % label)
    return real


def _under_allowed_base(real: str) -> bool:
    return any(real.startswith(base) for base in ALLOWED_BASES)


def _validate_owned_dir(path: str, label: str, ai_uid: int) -> str:
    real = _real_existing_dir(path, label)
    if not _under_allowed_base(real):
        _reject(
            "path_outside_allowed_base",
            "%s is outside /tmp, /var/tmp, /run/aegl-* or /var/lib/aegl-*" % label,
        )
    owner = os.stat(real).st_uid
    if owner != ai_uid:
        _reject("wrong_owner", "%s must be owned by uid %s" % (label, ai_uid))
    return real


def _validate_project(path: str) -> str:
    real = _real_existing_dir(path, "project")
    git = os.path.join(real, ".git")
    if os.path.islink(git):
        _reject("symlink_path", "project/.git must not be a symlink")
    if not (os.path.isdir(git) or os.path.isfile(git)):
        _reject("project_not_git", "project must contain .git")
    return real


def _read_contract_json(path: str, label: str) -> dict:
    if os.path.islink(path):
        _reject("symlink_path", "%s must not be a symlink" % label)
    if not os.path.isfile(path):
        _reject("missing_file", "%s is missing" % label)
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        _reject("bad_contract_json", "%s is not valid JSON: %s" % (label, exc))
    if not isinstance(value, dict):
        _reject("bad_contract_json", "%s must be a JSON object" % label)
    return value


def _validate_contract(package: str, worktree_real: str) -> str:
    pkg = _real_existing_dir(package, "contract_package")
    impl = _read_contract_json(
        os.path.join(pkg, "implementation-contract.json"),
        "implementation-contract.json",
    )
    ctx = _read_contract_json(
        os.path.join(pkg, "project-context.json"),
        "project-context.json",
    )

    source_root = ctx.get("source_root")
    if not isinstance(source_root, str) or not os.path.isabs(source_root):
        _reject("bad_source_root", "project-context.json source_root must be absolute")
    try:
        root = os.path.realpath(source_root, strict=True)
    except OSError:
        _reject("bad_source_root", "project-context.json source_root does not exist")
    if not os.path.isdir(root):
        _reject("bad_source_root", "project-context.json source_root is not a directory")
    if not (worktree_real == root or worktree_real.startswith(root + os.sep)):
        _reject("worktree_outside_source_root", "worktree is outside the contract source_root")

    rel = os.path.relpath(worktree_real, root).replace(os.sep, "/")
    allowed = impl.get("allowed_paths")
    if not isinstance(allowed, list) or not allowed:
        _reject("bad_allowed_paths", "implementation-contract.json allowed_paths must be a non-empty list")
    for item in allowed:
        if (
            not isinstance(item, str)
            or not item
            or os.path.isabs(item)
            or ".." in item.split("/")
        ):
            _reject("bad_allowed_paths", "allowed_paths entries must be relative and must not contain '..'")
    if not any(rel == item.rstrip("/") or rel.startswith(item.rstrip("/") + "/") for item in allowed):
        _reject("worktree_not_allowed", "worktree is not authorized by allowed_paths")
    return pkg


def validate_entry(entry: dict, *, ai_uid: int) -> dict:
    if not isinstance(entry, dict):
        _reject("invalid_entry", "entry must be an object")
    missing = [field for field in ENTRY_FIELDS if not isinstance(entry.get(field), str) or not entry[field]]
    if missing:
        _reject("missing_field", "missing or empty: %s" % ", ".join(missing))
    extra = sorted(set(entry) - set(ENTRY_FIELDS))
    if extra:
        _reject("unknown_field", "unexpected entry field(s): %s" % ", ".join(extra))

    worktree = _validate_owned_dir(entry["worktree"], "worktree", ai_uid)
    scratch = _validate_owned_dir(entry["scratch"], "scratch", ai_uid)
    project = _validate_project(entry["project"])
    contract = _validate_contract(entry["contract_package"], worktree)
    return {
        "worktree": worktree,
        "scratch": scratch,
        "project": project,
        "contract_package": contract,
    }


def _load_registry(path: str, *, require_root_owner: bool) -> dict:
    if os.path.islink(path):
        raise RegistryInvalid("registry_symlink", "registry must not be a symlink")
    if not os.path.exists(path):
        return {}
    st = os.stat(path)
    if not stat.S_ISREG(st.st_mode):
        raise RegistryInvalid("registry_not_regular", "registry is not a regular file")
    if require_root_owner and st.st_uid != 0:
        raise RegistryInvalid("registry_not_root_owned", "registry must be owned by root")
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryInvalid("bad_registry_json", "registry is not valid JSON: %s" % exc) from exc
    if not isinstance(data, dict):
        raise RegistryInvalid("registry_not_object", "registry must be a JSON object")
    for task_id, entry in data.items():
        if not isinstance(task_id, str) or not TASK_ID_RE.fullmatch(task_id):
            raise RegistryInvalid("bad_existing_task_id", "invalid existing task_id: %r" % (task_id,))
        if not isinstance(entry, dict):
            raise RegistryInvalid("bad_existing_entry", "entry for %s is not an object" % task_id)
        missing = [field for field in ENTRY_FIELDS if not isinstance(entry.get(field), str) or not entry[field]]
        if missing:
            raise RegistryInvalid(
                "bad_existing_entry",
                "entry for %s missing: %s" % (task_id, ", ".join(missing)),
            )
    return data


def _check_registry_dir(dirpath: str, *, require_root_owner: bool) -> None:
    st = os.stat(dirpath)
    if not stat.S_ISDIR(st.st_mode):
        raise RegistryInvalid("registry_dir", "registry parent is not a directory")
    if require_root_owner:
        if st.st_uid != 0:
            raise RegistryInvalid("registry_dir_not_root", "registry parent must be owned by root")
        if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise RegistryInvalid("registry_dir_writable", "registry parent must not be group/other writable")


def _open_lock(lock_path: str, *, require_root_owner: bool) -> int:
    if os.path.islink(lock_path):
        raise RegistryInvalid("lock_symlink", "lock file must not be a symlink")
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    except OSError as exc:
        raise RegistryError("lock_io", "cannot open lock file: %s" % exc) from exc
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise RegistryInvalid("lock_not_regular", "lock file is not a regular file")
        if require_root_owner and st.st_uid != 0:
            raise RegistryInvalid("lock_not_root_owned", "lock file must be owned by root")
        os.fchmod(fd, 0o600)
    except Exception:
        os.close(fd)
        raise
    return fd


def _fsync_dir(dirpath: str) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    fd = os.open(dirpath, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _atomic_write(path: str, data: dict, *, require_root_owner: bool) -> None:
    dirpath = os.path.dirname(path) or "."
    _check_registry_dir(dirpath, require_root_owner=require_root_owner)
    if os.path.islink(path):
        raise RegistryInvalid("registry_symlink", "registry must not be a symlink")

    if os.path.exists(path):
        st = os.stat(path)
        if not stat.S_ISREG(st.st_mode):
            raise RegistryInvalid("registry_not_regular", "registry is not a regular file")
        if require_root_owner and st.st_uid != 0:
            raise RegistryInvalid("registry_not_root_owned", "registry must be owned by root")
        mode = stat.S_IMODE(st.st_mode)
        uid, gid = st.st_uid, st.st_gid
    else:
        mode = 0o644
        uid, gid = (0, 0) if require_root_owner else (os.getuid(), os.getgid())

    fd, tmp = tempfile.mkstemp(prefix=".registry.", dir=dirpath)
    replaced = False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)
            if (uid, gid) != (os.getuid(), os.getgid()):
                os.fchown(handle.fileno(), uid, gid)
        try:
            os.replace(tmp, path)
        except OSError as exc:
            raise RegistryError("replace_io", "registry replace failed: %s" % exc) from exc
        replaced = True
        try:
            _fsync_dir(dirpath)
        except OSError as exc:
            raise DurabilityError(
                "dir_fsync_failed",
                "registry was replaced, but directory fsync failed; durability is uncertain",
            ) from exc
    finally:
        if not replaced:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def register(
    registry_path: str,
    task_id: str,
    *,
    worktree: str,
    scratch: str,
    project: str,
    contract_package: str,
    ai_uid: int,
    require_root_owner: bool = False,
) -> dict:
    validate_task_id(task_id)
    entry = validate_entry(
        {
            "worktree": worktree,
            "scratch": scratch,
            "project": project,
            "contract_package": contract_package,
        },
        ai_uid=ai_uid,
    )

    dirpath = os.path.dirname(registry_path) or "."
    if not os.path.isdir(dirpath):
        raise RegistryError("registry_dir_missing", "registry parent does not exist: %s" % dirpath)

    lock_path = registry_path + ".lock"
    lock_fd = _open_lock(lock_path, require_root_owner=require_root_owner)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        registry = _load_registry(registry_path, require_root_owner=require_root_owner)
        if task_id in registry:
            raise ValidationError("duplicate_task_id", "task_id already registered: %s" % task_id)
        registry[task_id] = entry
        _atomic_write(registry_path, registry, require_root_owner=require_root_owner)
        return entry
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)


def show(registry_path: str, task_id: str, *, require_root_owner: bool = False) -> dict:
    validate_task_id(task_id)
    registry = _load_registry(registry_path, require_root_owner=require_root_owner)
    if task_id not in registry:
        raise NotFoundError("not_found", "task_id not registered: %s" % task_id)
    return registry[task_id]


def list_tasks(registry_path: str, *, require_root_owner: bool = False) -> list:
    registry = _load_registry(registry_path, require_root_owner=require_root_owner)
    return sorted(registry)


def _ai_uid() -> int:
    try:
        return pwd.getpwnam(AI_USER).pw_uid
    except KeyError:
        raise RegistryInvalid("ai_user_missing", "required identity not found: %s" % AI_USER)


def _print_error(exc: RegistryError) -> None:
    if exc.exit_code == EXIT_VALIDATION:
        prefix = "REJECTED"
    elif exc.exit_code == EXIT_DURABILITY:
        prefix = "REPLACED_DURABILITY_UNCERTAIN"
    elif exc.exit_code == EXIT_NOT_FOUND:
        prefix = "NOT_FOUND"
    else:
        prefix = "FAILED"
    print("%s reason=%s: %s" % (prefix, exc.reason, exc.message), file=sys.stderr)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aegl-model-task",
        description="Root-only trusted Hermes task registry (register/query only).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    reg = sub.add_parser("register", help="register one task (root only)")
    reg.add_argument("--task-id", required=True)
    reg.add_argument("--worktree", required=True)
    reg.add_argument("--scratch", required=True)
    reg.add_argument("--project", required=True)
    reg.add_argument("--contract-package", required=True)

    show_p = sub.add_parser("show", help="show one registered task")
    show_p.add_argument("--task-id", required=True)

    sub.add_parser("list", help="list registered task ids")
    return parser


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    if args.command == "register":
        if os.geteuid() != 0:
            print("REJECTED reason=not_root: register requires root", file=sys.stderr)
            return EXIT_USAGE
        try:
            entry = register(
                PRODUCTION_REGISTRY,
                args.task_id,
                worktree=args.worktree,
                scratch=args.scratch,
                project=args.project,
                contract_package=args.contract_package,
                ai_uid=_ai_uid(),
                require_root_owner=True,
            )
        except RegistryError as exc:
            _print_error(exc)
            return exc.exit_code
        print("REGISTERED task_id=%s worktree=%s" % (args.task_id, entry["worktree"]))
        return EXIT_OK

    try:
        if args.command == "show":
            entry = show(PRODUCTION_REGISTRY, args.task_id, require_root_owner=False)
            print(json.dumps(entry, indent=2, sort_keys=True))
            return EXIT_OK
        tasks = list_tasks(PRODUCTION_REGISTRY, require_root_owner=False)
        for task_id in tasks:
            print(task_id)
        return EXIT_OK
    except RegistryError as exc:
        _print_error(exc)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
