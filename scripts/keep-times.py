#!/usr/bin/env python3
"""Keeps the modification times of files a re-prepare rewrites with the same
contents, so the next build recompiles only what really changed.

    scripts/keep-times.py save STATE TREE...
    scripts/keep-times.py restore STATE

save records, for every file git sees as changed or added in each TREE (the
patched files), its contents' hash and its times, in the file STATE.
restore gives those times back to the files whose contents are still the
same, and deletes STATE.

prepare.sh runs it around checking out and patching again: checking out
rewrites every patched file and patching rewrites it once more, which
would otherwise make the build recompile all of them, and everything that
includes them, after any change to any patch.
"""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def changed_files(tree: Path) -> list[Path]:
    status = subprocess.run(
        ["git", "-C", str(tree), "status", "--porcelain=v1", "-z", "--untracked-files=all",
         "--no-renames", "--ignore-submodules=all"],
        check=True, stdout=subprocess.PIPE).stdout
    files = []
    for entry in status.split(b"\0"):
        if len(entry) > 3:
            path = tree / os.fsdecode(entry[3:])
            if path.is_file() and not path.is_symlink():
                files.append(path)
    return files


def save(state: Path, trees: list[Path]) -> None:
    saved = {}
    for tree in trees:
        if not (tree / ".git").exists():
            continue
        for path in changed_files(tree):
            info = path.stat()
            saved[str(path)] = [digest(path), info.st_atime_ns, info.st_mtime_ns]
    state.write_text(json.dumps(saved))
    print(f"Remembered the times of {len(saved)} patched files")


def restore(state: Path) -> None:
    if not state.is_file():
        return
    kept = 0
    for name, (sha, atime, mtime) in json.loads(state.read_text()).items():
        path = Path(name)
        if path.is_file() and not path.is_symlink() and digest(path) == sha:
            os.utime(path, ns=(atime, mtime))
            kept += 1
    state.unlink()
    print(f"Kept the times of {kept} unchanged files")


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[1] == "save":
        save(Path(argv[2]), [Path(t) for t in argv[3:]])
    elif len(argv) == 3 and argv[1] == "restore":
        restore(Path(argv[2]))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
