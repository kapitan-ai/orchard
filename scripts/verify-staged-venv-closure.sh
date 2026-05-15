#!/bin/bash
#
# Verify staged Python virtualenvs are self-contained enough for PKG payload signing.
# Usage: scripts/verify-staged-venv-closure.sh [--no-smoke] <staging-root>

set -euo pipefail

usage() {
    echo "Usage: $0 [--no-smoke] <staging-root>" >&2
}

RUN_SMOKE=true
if [[ $# -gt 0 && "$1" == "--no-smoke" ]]; then
    RUN_SMOKE=false
    shift
fi

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

ROOT="$1"
if [[ ! -d "$ROOT" ]]; then
    echo "error: staging root does not exist: $ROOT" >&2
    exit 66
fi

python3 - "$ROOT" "$RUN_SMOKE" <<'PY'
import os
import pathlib
import subprocess
import sys
from typing import Optional

root = pathlib.Path(sys.argv[1]).resolve()
run_smoke = sys.argv[2] == "true"
payload_rel = pathlib.Path("Library/Application Support/Orchard")
install_prefix = pathlib.Path("/Library/Application Support/Orchard")
allowed_system_prefixes = ("/usr/lib/", "/System/Library/")
forbidden_cfg_fragments = ("/Users/", "/private/var", "/var/folders/", ".local/share/uv")
errors: list[str] = []


def rel(path: pathlib.Path) -> str:
    try:
        return str(path.resolve(strict=False).relative_to(root))
    except ValueError:
        return str(path)


def command_stdout(argv: list[str]) -> tuple[int, str, str]:
    completed = subprocess.run(argv, text=True, capture_output=True, check=False)
    return completed.returncode, completed.stdout, completed.stderr


def is_macho(path: pathlib.Path) -> bool:
    rc, stdout, stderr = command_stdout(["file", "-b", "--mime-type", str(path)])
    if rc != 0:
        errors.append(f"file failed: {rel(path)}: {stderr.strip()}")
        return False
    return "application/x-mach-binary" in stdout


def discover_venvs() -> list[pathlib.Path]:
    found: list[pathlib.Path] = []
    if root.name == ".venv":
        found.append(root)
    for path in root.rglob(".venv"):
        if path.is_dir() and path not in found:
            found.append(path)
    return sorted(found)


def expand_macho_path(
    token: str,
    macho: pathlib.Path,
    executable_dir: pathlib.Path,
    rpath: Optional[pathlib.Path] = None,
) -> Optional[pathlib.Path]:
    if token == "@loader_path":
        return macho.parent
    if token.startswith("@loader_path/"):
        return macho.parent / token.removeprefix("@loader_path/")
    if token == "@executable_path":
        return executable_dir
    if token.startswith("@executable_path/"):
        return executable_dir / token.removeprefix("@executable_path/")
    if token.startswith("@rpath/") and rpath is not None:
        return rpath / token.removeprefix("@rpath/")
    if token.startswith("/"):
        return pathlib.Path(token)
    return None


def strip_otool_path(value: str, field: str) -> str:
    return value.removeprefix(field + " ").rsplit(" (", 1)[0]


def is_system_path(path: pathlib.Path) -> bool:
    return str(path).startswith(allowed_system_prefixes)


def is_in_staging_root(path: pathlib.Path) -> bool:
    return str(path).startswith(str(root) + os.sep)


def map_install_prefix(path: pathlib.Path) -> Optional[pathlib.Path]:
    try:
        install_relative = path.relative_to(install_prefix)
    except ValueError:
        return None

    candidates = [
        root / payload_rel / install_relative,
        root / "Payload" / payload_rel / install_relative,
        root / install_relative,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def is_allowed_resolved_path(path: pathlib.Path) -> bool:
    return is_system_path(path) or is_in_staging_root(path)


def is_allowed_raw_absolute_dep(path: pathlib.Path) -> bool:
    if is_system_path(path):
        return True
    mapped = map_install_prefix(path)
    return mapped is not None and mapped.exists()


def parse_macho_loads(macho: pathlib.Path, executable_dir: pathlib.Path) -> tuple[list[pathlib.Path], list[str]]:
    rc, stdout, stderr = command_stdout(["otool", "-l", str(macho)])
    if rc != 0:
        errors.append(f"otool -l failed: {rel(macho)}: {stderr.strip()}")
        return [], []

    rpaths: list[pathlib.Path] = []
    deps: list[str] = []
    load_commands = {
        "LC_LOAD_DYLIB",
        "LC_LOAD_WEAK_DYLIB",
        "LC_REEXPORT_DYLIB",
        "LC_LOAD_UPWARD_DYLIB",
        "LC_LAZY_LOAD_DYLIB",
    }
    lines = stdout.splitlines()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "cmd LC_RPATH":
            for candidate in lines[index + 1:index + 6]:
                candidate = candidate.strip()
                if not candidate.startswith("path "):
                    continue
                rpath_token = strip_otool_path(candidate, "path")
                expanded = expand_macho_path(rpath_token, macho, executable_dir)
                if expanded is None:
                    errors.append(f"unresolved LC_RPATH: {rel(macho)} -> {rpath_token}")
                    continue
                mapped = map_install_prefix(expanded) if expanded.is_absolute() else None
                expanded = (mapped if mapped is not None else expanded).resolve(strict=False)
                if rpath_token in ("@loader_path", "@executable_path") or rpath_token.startswith(("@loader_path/", "@executable_path/")):
                    allowed = is_allowed_resolved_path(expanded)
                else:
                    allowed = is_system_path(expanded) or (mapped is not None and mapped.exists())
                if expanded.is_absolute() and not allowed:
                    errors.append(f"outbound LC_RPATH: {rel(macho)} -> {expanded}")
                    continue
                rpaths.append(expanded)
                break
        elif stripped.startswith("cmd ") and stripped.split(" ", 1)[1] in load_commands:
            for candidate in lines[index + 1:index + 8]:
                candidate = candidate.strip()
                if not candidate.startswith("name "):
                    continue
                deps.append(strip_otool_path(candidate, "name"))
                break
    return rpaths, deps


venvs = discover_venvs()
if not venvs:
    errors.append(f"no .venv directories found under {root}")

for venv in venvs:
    venv_real = venv.resolve(strict=False)
    python = venv / "bin" / "python"

    if python.is_symlink():
        errors.append(f"interpreter is symlink: {rel(python)} -> {os.readlink(python)}")
    elif not python.is_file():
        errors.append(f"interpreter missing: {rel(python)}")
    elif not is_macho(python):
        errors.append(f"interpreter is not Mach-O: {rel(python)}")

    cfg = venv / "pyvenv.cfg"
    if cfg.exists():
        text = cfg.read_text(errors="replace")
        for fragment in forbidden_cfg_fragments:
            if fragment in text:
                errors.append(f"pyvenv.cfg has build-host path fragment {fragment!r}: {rel(cfg)}")
                break

    for entry in venv.rglob("*"):
        if not entry.is_symlink():
            continue
        try:
            resolved = entry.resolve(strict=True)
        except FileNotFoundError:
            errors.append(f"dangling symlink: {rel(entry)} -> {os.readlink(entry)}")
            continue

        resolved_s = str(resolved)
        if resolved_s.startswith(str(venv_real) + os.sep):
            continue
        if resolved_s.startswith(allowed_system_prefixes):
            continue
        errors.append(f"outbound symlink: {rel(entry)} -> {resolved_s}")

    for script in (venv / "bin").glob("*"):
        if script.is_symlink() or not script.is_file() or is_macho(script):
            continue
        try:
            first_line = script.read_text(errors="replace").splitlines()[0]
        except IndexError:
            continue
        if not first_line.startswith("#!"):
            continue
        for fragment in forbidden_cfg_fragments:
            if fragment in first_line:
                errors.append(f"script shebang has build-host path fragment {fragment!r}: {rel(script)}")
                break

    executable_dir = python.parent

    for entry in venv.rglob("*"):
        if not entry.is_file() or entry.is_symlink():
            continue
        if not is_macho(entry):
            continue

        rpaths, deps = parse_macho_loads(entry, executable_dir)
        for dep in deps:
            if dep.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if dep.startswith(("@loader_path/", "@executable_path/")):
                resolved = expand_macho_path(dep, entry, executable_dir)
                resolved = resolved.resolve(strict=False) if resolved is not None else None
                if resolved is None or not resolved.exists():
                    errors.append(f"unresolved Mach-O dependency: {rel(entry)} -> {dep}")
                elif not is_allowed_resolved_path(resolved):
                    errors.append(f"outbound Mach-O dependency: {rel(entry)} -> {dep} -> {resolved}")
                continue
            if dep.startswith("@rpath/"):
                candidates = [expand_macho_path(dep, entry, executable_dir, rpath) for rpath in rpaths]
                resolved_candidates = [candidate.resolve(strict=False) for candidate in candidates if candidate is not None]
                if not any(candidate.exists() and is_allowed_resolved_path(candidate) for candidate in resolved_candidates):
                    detail = ", ".join(str(candidate) for candidate in resolved_candidates) or "no LC_RPATH"
                    errors.append(f"unresolved @rpath dependency: {rel(entry)} -> {dep} ({detail})")
                continue
            if dep.startswith("/") and not is_allowed_raw_absolute_dep(pathlib.Path(dep)):
                errors.append(f"outbound Mach-O dependency: {rel(entry)} -> {dep}")

    if run_smoke and python.exists() and not python.is_symlink():
        smoke = subprocess.run(
            [str(python), "-c", "import sys; print(sys.executable)"],
            text=True,
            capture_output=True,
            check=False,
            env={"PATH": "/usr/bin:/bin", "HOME": "/tmp"},
        )
        if smoke.returncode != 0:
            detail = (smoke.stderr or smoke.stdout).strip()
            errors.append(f"sanitized interpreter smoke failed: {rel(python)}: {detail}")

if errors:
    print("\n".join(errors))
    sys.exit(1)

for venv in venvs:
    print(f"ok\t{rel(venv)}")
PY
