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


class PrecommitIOError(RegistryError):
    exit_code = EXIT_IO


class NotFoundError(RegistryError):
    exit_code = EXIT_NOT_FOUND


def _reject(reason: str, message: str) -> None:
    raise ValidationError(reason, message)


def _fail(error_cls, reason: str, message: str) -> None:
    raise error_cls(reason, message)


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


def _check_trusted_dir(path: str, label: str, *, trusted_uid: int) -> None:
    if os.path.islink(path):
        _reject("symlink_path", "%s must not be a symlink" % label)
    st = os.stat(path, follow_symlinks=False)
    if not stat.S_ISDIR(st.st_mode):
        _reject("not_a_directory", "%s is not a directory" % label)
    if st.st_uid not in (0, trusted_uid):
        _reject("contract_not_trusted", "%s must be root-controlled" % label)
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        _reject("contract_writable", "%s must not be group/other writable" % label)


def _check_trusted_file(path: str, label: str, *, trusted_uid: int) -> None:
    if os.path.islink(path):
        _reject("symlink_path", "%s must not be a symlink" % label)
    st = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(st.st_mode):
        _reject("not_a_regular_file", "%s is not a regular file" % label)
    if st.st_uid not in (0, trusted_uid):
        _reject("contract_file_not_trusted", "%s must be root-controlled" % label)
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        _reject("contract_file_writable", "%s must not be group/other writable" % label)


def _check_trusted_parent_chain(
    path: str,
    label: str,
    *,
    trusted_uid: int,
    reason_prefix: str,
    error_cls,
) -> None:
    parent = os.path.dirname(path)
    while True:
        if os.path.islink(parent):
            _fail(error_cls, "symlink_path", "%s parent must not be a symlink: %s" % (label, parent))
        st = os.stat(parent, follow_symlinks=False)
        if not stat.S_ISDIR(st.st_mode):
            _fail(error_cls, "not_a_directory", "%s parent is not a directory: %s" % (label, parent))
        if st.st_uid not in (0, trusted_uid):
            _fail(
                error_cls,
                reason_prefix + "_parent_not_trusted",
                "%s parent must be root-controlled: %s" % (label, parent),
            )
        if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH) and not (st.st_mode & stat.S_ISVTX):
            _fail(
                error_cls,
                reason_prefix + "_parent_writable",
                "%s parent is writable by untrusted identities: %s" % (label, parent),
            )
        if parent == "/":
            break
        parent = os.path.dirname(parent)


def _read_contract_json(path: str, label: str, *, trusted_uid: int) -> dict:
    _check_trusted_file(path, label, trusted_uid=trusted_uid)
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        _reject("bad_contract_json", "%s is not valid JSON: %s" % (label, exc))
    if not isinstance(value, dict):
        _reject("bad_contract_json", "%s must be a JSON object" % label)
    return value


def _validate_contract(package: str, worktree_real: str, *, trusted_uid: int) -> str:
    pkg = _real_existing_dir(package, "contract_package")
    _check_trusted_dir(pkg, "contract_package", trusted_uid=trusted_uid)
    _check_trusted_parent_chain(
        pkg,
        "contract_package",
        trusted_uid=trusted_uid,
        reason_prefix="contract",
        error_cls=ValidationError,
    )
    impl = _read_contract_json(
        os.path.join(pkg, "implementation-contract.json"),
        "implementation-contract.json",
        trusted_uid=trusted_uid,
    )
    ctx = _read_contract_json(
        os.path.join(pkg, "project-context.json"),
        "project-context.json",
        trusted_uid=trusted_uid,
    )

    source_root = ctx.get("source_root")
    if not isinstance(source_root, str) or not os.path.isabs(source_root):
        _reject("bad_source_root", "project-context.json source_root must be absolute")
    if os.path.islink(source_root):
        _reject("symlink_path", "project-context.json source_root must not be a symlink")
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


def validate_entry(entry: dict, *, ai_uid: int, trusted_uid: int | None = None) -> dict:
    if trusted_uid is None:
        trusted_uid = os.getuid()
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
    contract = _validate_contract(entry["contract_package"], worktree, trusted_uid=trusted_uid)
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
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RegistryInvalid("registry_writable", "registry must not be group/other writable")
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
    trusted_uid = 0 if require_root_owner else os.getuid()
    if os.path.islink(dirpath):
        raise RegistryInvalid("registry_dir_symlink", "registry parent must not be a symlink")
    st = os.stat(dirpath, follow_symlinks=False)
    if not stat.S_ISDIR(st.st_mode):
        raise RegistryInvalid("registry_dir", "registry parent is not a directory")
    if st.st_uid not in (0, trusted_uid):
        raise RegistryInvalid("registry_dir_not_root", "registry parent must be root-controlled")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RegistryInvalid("registry_dir_writable", "registry parent must not be group/other writable")
    _check_trusted_parent_chain(
        dirpath,
        "registry_dir",
        trusted_uid=trusted_uid,
        reason_prefix="registry",
        error_cls=RegistryInvalid,
    )


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
        if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise RegistryInvalid("lock_writable", "lock file must not be group/other writable")
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
        if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise RegistryInvalid("registry_writable", "registry must not be group/other writable")
        mode = stat.S_IMODE(st.st_mode)
        uid, gid = st.st_uid, st.st_gid
    else:
        mode = 0o644
        uid, gid = (0, 0) if require_root_owner else (os.getuid(), os.getgid())

    try:
        fd, tmp = tempfile.mkstemp(prefix=".registry.", dir=dirpath)
    except OSError as exc:
        raise PrecommitIOError("precommit_io", "temp file creation failed: %s" % exc) from exc

    replaced = False
    fd_owned = True
    try:
        try:
            handle = os.fdopen(fd, "w", encoding="utf-8")
            fd_owned = False
            with handle:
                json.dump(data, handle, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fchmod(handle.fileno(), mode)
                if (uid, gid) != (os.getuid(), os.getgid()):
                    os.fchown(handle.fileno(), uid, gid)
                os.fsync(handle.fileno())
        except OSError as exc:
            raise PrecommitIOError(
                "precommit_io",
                "pre-commit write/metadata/fsync failed: %s" % exc,
            ) from exc

        try:
            os.replace(tmp, path)
        except OSError as exc:
            raise PrecommitIOError("precommit_io", "registry replace failed: %s" % exc) from exc
        replaced = True

        try:
            _fsync_dir(dirpath)
        except OSError as exc:
            raise DurabilityError(
                "dir_fsync_failed",
                "registry was replaced, but directory fsync failed; durability is uncertain",
            ) from exc
    finally:
        if fd_owned:
            try:
                os.close(fd)
            except OSError:
                pass
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
    trusted_uid: int | None = None,
    require_root_owner: bool = False,
) -> dict:
    if trusted_uid is None:
        trusted_uid = 0 if require_root_owner else os.getuid()
    validate_task_id(task_id)
    entry = validate_entry(
        {
            "worktree": worktree,
            "scratch": scratch,
            "project": project,
            "contract_package": contract_package,
        },
        ai_uid=ai_uid,
        trusted_uid=trusted_uid,
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
                trusted_uid=0,
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
