#!/bin/bash
#
# Copy uv-managed Python interpreter/runtime files into staged native virtualenvs.
# Usage: scripts/materialize-staged-venv-interpreters.sh <staged-native-root>

set -euo pipefail

usage() {
    echo "Usage: $0 <staged-native-root>" >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

NATIVE_ROOT="$1"
if [[ ! -d "$NATIVE_ROOT" ]]; then
    echo "error: staged native root does not exist: $NATIVE_ROOT" >&2
    exit 66
fi

python3 - "$NATIVE_ROOT" <<'PY'
import os
import pathlib
import shutil
import stat
import subprocess
import sys
from typing import Optional

native_root = pathlib.Path(sys.argv[1])


def copy_without_metadata(src: pathlib.Path, dst: pathlib.Path) -> pathlib.Path:
    shutil.copyfile(src, dst)
    shutil.copymode(src, dst, follow_symlinks=False)
    return dst


def command_stdout(argv: list[str]) -> tuple[int, str, str]:
    completed = subprocess.run(argv, text=True, capture_output=True, check=False)
    return completed.returncode, completed.stdout, completed.stderr


def is_within(path: pathlib.Path, base: pathlib.Path) -> bool:
    resolved = path.resolve(strict=False)
    base_resolved = base.resolve(strict=False)
    return str(resolved) == str(base_resolved) or str(resolved).startswith(str(base_resolved) + os.sep)


def is_macho(path: pathlib.Path) -> bool:
    rc, stdout, stderr = command_stdout(["file", "-b", "--mime-type", str(path)])
    if rc != 0:
        raise SystemExit(f"file failed for {path}: {stderr.strip()}")
    return "application/x-mach-binary" in stdout


def strip_otool_path(value: str, field: str) -> str:
    return value.removeprefix(field + " ").rsplit(" (", 1)[0]


def otool_sections(lines: list[str]) -> list[list[str]]:
    sections: list[list[str]] = []
    current: list[str] = []
    for line in lines:
        if ("(for architecture " in line or "(architecture " in line) and current:
            sections.append(current)
            current = []
        current.append(line)
    if current:
        sections.append(current)
    return sections


def parse_macho_loads(macho: pathlib.Path) -> list[tuple[list[str], list[str]]]:
    rc, stdout, stderr = command_stdout(["otool", "-arch", "all", "-l", str(macho)])
    if rc != 0:
        raise SystemExit(f"otool -l failed for {macho}: {stderr.strip()}")

    parsed: list[tuple[list[str], list[str]]] = []
    load_commands = {
        "LC_LOAD_DYLIB",
        "LC_LOAD_WEAK_DYLIB",
        "LC_REEXPORT_DYLIB",
        "LC_LOAD_UPWARD_DYLIB",
        "LC_LAZY_LOAD_DYLIB",
    }
    for lines in otool_sections(stdout.splitlines()):
        rpaths: list[str] = []
        deps: list[str] = []
        for index, raw_line in enumerate(lines):
            if raw_line.strip() != "cmd LC_RPATH":
                continue
            for candidate in lines[index + 1:index + 6]:
                candidate = candidate.strip()
                if candidate.startswith("path "):
                    rpaths.append(strip_otool_path(candidate, "path"))
                    break
        for index, raw_line in enumerate(lines):
            stripped = raw_line.strip()
            if stripped.startswith("cmd ") and stripped.split(" ", 1)[1] in load_commands:
                for candidate in lines[index + 1:index + 8]:
                    candidate = candidate.strip()
                    if candidate.startswith("name "):
                        deps.append(strip_otool_path(candidate, "name"))
                        break
        parsed.append((rpaths, deps))
    return parsed


def expand_path_token(token: str, macho: pathlib.Path, executable_dir: Optional[pathlib.Path]) -> Optional[pathlib.Path]:
    if token == "@loader_path":
        return macho.parent
    if token.startswith("@loader_path/"):
        return macho.parent / token.removeprefix("@loader_path/")
    if token == "@executable_path":
        return executable_dir
    if token.startswith("@executable_path/"):
        if executable_dir is None:
            return None
        return executable_dir / token.removeprefix("@executable_path/")
    if token.startswith("/"):
        return pathlib.Path(token)
    return None


def rpath_resolves_in_venv(
    dep: str,
    macho: pathlib.Path,
    executable_dir: pathlib.Path,
    rpaths: list[str],
    venv: pathlib.Path,
) -> bool:
    dep_suffix = dep.removeprefix("@rpath/")
    for rpath in rpaths:
        expanded = expand_path_token(rpath, macho, executable_dir)
        if expanded is None:
            continue
        candidate = (expanded / dep_suffix).resolve(strict=False)
        if candidate.is_file() and is_within(candidate, venv):
            return True
    return False


def in_venv_candidate_dirs(venv: pathlib.Path, basename: str) -> list[pathlib.Path]:
    dirs: set[pathlib.Path] = set()
    for candidate in venv.rglob(basename):
        if candidate.is_symlink() or not candidate.is_file():
            continue
        resolved = candidate.resolve(strict=False)
        if is_within(resolved, venv):
            dirs.add(resolved.parent)
    return sorted(dirs)


def loader_path_rpath(macho: pathlib.Path, candidate_dir: pathlib.Path) -> str:
    relative = os.path.relpath(candidate_dir.resolve(strict=False), macho.parent.resolve(strict=False))
    if relative == ".":
        return "@loader_path"
    return "@loader_path/" + relative.replace(os.sep, "/")


def python_launcher_body(text: str) -> Optional[str]:
    lines = text.splitlines(keepends=True)
    if not lines or not lines[0].startswith("#!"):
        return None
    if "python" in lines[0]:
        return "".join(lines[1:])
    if (
        len(lines) >= 3
        and lines[0].rstrip("\r\n") in {"#!/bin/sh", "#!/usr/bin/env sh"}
        and lines[1].lstrip().startswith("'''exec' ")
        and "python" in lines[1]
        and '"$0" "$@"' in lines[1]
        and lines[2].strip() == "' '''"
    ):
        return "".join(lines[3:])
    return None


def remediate_venv_rpath_deps(venv: pathlib.Path) -> None:
    executable_dir = venv / "bin"
    added_rpaths: set[tuple[pathlib.Path, str]] = set()
    machos = sorted(
        path
        for path in venv.rglob("*")
        if not path.is_symlink() and path.is_file() and is_macho(path)
    )
    for macho in machos:
        for rpaths, deps in parse_macho_loads(macho):
            for dep in deps:
                if not dep.startswith("@rpath/") or not dep.endswith(".dylib"):
                    continue
                if rpath_resolves_in_venv(dep, macho, executable_dir, rpaths, venv):
                    continue
                basename = pathlib.Path(dep).name
                candidate_dirs = in_venv_candidate_dirs(venv, basename)
                if not candidate_dirs:
                    raise SystemExit(f"unresolved @rpath dependency has no in-venv candidate: {macho} -> {dep}")
                if len(candidate_dirs) > 1:
                    rendered = ", ".join(str(path) for path in candidate_dirs)
                    raise SystemExit(f"ambiguous in-venv candidates for {dep}: {rendered}")
                new_rpath = loader_path_rpath(macho, candidate_dirs[0])
                added_key = (macho, new_rpath)
                if added_key in added_rpaths:
                    continue
                subprocess.run(["install_name_tool", "-add_rpath", new_rpath, str(macho)], check=True)
                added_rpaths.add(added_key)


venvs = sorted(path for path in native_root.glob("*/.venv") if path.is_dir())
if not venvs:
    raise SystemExit(f"no staged native virtualenvs found under {native_root}")

for venv in venvs:
    python = venv / "bin" / "python"
    if not python.exists():
        raise SystemExit(f"missing venv interpreter: {python}")

    resolved_python = python.resolve(strict=True)
    runtime_prefix = resolved_python.parent.parent
    runtime_lib = runtime_prefix / "lib"
    if not runtime_lib.is_dir():
        raise SystemExit(f"missing Python runtime lib directory for {python}: {runtime_lib}")

    if python.is_symlink():
        python.unlink()
        copy_without_metadata(resolved_python, python)
        python.chmod(python.stat().st_mode | 0o755)

    venv_real = venv.resolve(strict=False)
    for interpreter_link in sorted((venv / "bin").glob("python*")):
        if not interpreter_link.is_symlink():
            continue
        resolved = interpreter_link.resolve(strict=True)
        if str(resolved).startswith(str(venv_real) + os.sep):
            continue
        interpreter_link.unlink()
        copy_without_metadata(resolved, interpreter_link)
        interpreter_link.chmod(interpreter_link.stat().st_mode | 0o755)

    staged_lib = venv / "lib"
    staged_lib.mkdir(parents=True, exist_ok=True)
    if runtime_lib.resolve(strict=True) != staged_lib.resolve(strict=False):
        shutil.copytree(runtime_lib, staged_lib, dirs_exist_ok=True, copy_function=copy_without_metadata)

    for libpython in staged_lib.glob("libpython*.dylib"):
        subprocess.run(
            ["install_name_tool", "-id", f"@rpath/{libpython.name}", str(libpython)],
            check=True,
        )

    bin_dir = venv / "bin"
    for script in sorted(bin_dir.iterdir()):
        if script.is_symlink() or not script.is_file() or script == python:
            continue
        mode = script.stat().st_mode
        if not (mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)):
            continue
        try:
            raw = script.read_bytes()
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        body = python_launcher_body(text)
        if body is None:
            continue
        launcher = "#!/bin/sh\n'''exec' \"$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)/python\" \"$0\" \"$@\"\n' '''\n"
        script.write_text(launcher + body)
        os.chmod(script, mode)

    cfg = venv / "pyvenv.cfg"
    if cfg.exists():
        lines = [line for line in cfg.read_text().splitlines() if not line.startswith("home = ")]
        cfg.write_text("\n".join(lines) + "\n")

    remediate_venv_rpath_deps(venv)

    print(f"materialized\t{venv}")
PY
