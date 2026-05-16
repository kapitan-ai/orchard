#!/bin/bash
#
# Bundle Homebrew-linked OpenSSL dylibs referenced by OTP Mach-O files and
# rewrite those load commands to payload-relative @loader_path references.
# Usage: scripts/remediate-otp-openssl-closure.sh [--provenance-output <path>] <staging-root>

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/remediate-otp-openssl-closure.sh [--provenance-output <path>] <staging-root>

Scans the staged Orchard payload for Mach-O load commands pointing at Homebrew
OpenSSL libcrypto/libssl dylibs, copies those dylibs into the payload under
support/openssl/lib, rewrites load commands to @loader_path-relative paths, and
writes optional provenance evidence outside the staging root.
EOF
}

PROVENANCE_OUTPUT=""
STAGING_ROOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provenance-output)
            if [[ $# -lt 2 ]]; then
                echo "error: missing value for --provenance-output" >&2
                usage >&2
                exit 64
            fi
            PROVENANCE_OUTPUT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
        *)
            if [[ -n "$STAGING_ROOT" ]]; then
                echo "error: only one staging root may be supplied" >&2
                usage >&2
                exit 64
            fi
            STAGING_ROOT="$1"
            shift
            ;;
    esac
done

if [[ -z "$STAGING_ROOT" || ! -d "$STAGING_ROOT" ]]; then
    echo "error: staging root does not exist: ${STAGING_ROOT:-<missing>}" >&2
    exit 66
fi

for required in python3 file otool install_name_tool shasum; do
    if ! command -v "$required" >/dev/null 2>&1; then
        echo "error: $required is required but was not found on PATH" >&2
        exit 69
    fi
done

python3 - "$STAGING_ROOT" "$PROVENANCE_OUTPUT" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys
from collections import OrderedDict
from typing import Optional

staging_root = pathlib.Path(sys.argv[1]).resolve()
provenance_output = sys.argv[2]
if provenance_output:
    provenance_path = pathlib.Path(provenance_output).resolve()
    if str(provenance_path) == str(staging_root) or str(provenance_path).startswith(str(staging_root) + os.sep):
        raise SystemExit("error: --provenance-output must be outside the staging root")
bundle_dir = staging_root / "support" / "openssl" / "lib"
source_to_dest: "OrderedDict[str, pathlib.Path]" = OrderedDict()
source_paths: dict[str, pathlib.Path] = {}
rewrites: list[tuple[pathlib.Path, str, str]] = []
deleted_rpaths: set[tuple[pathlib.Path, str]] = set()


def run(argv: list[str], *, check: bool = False) -> tuple[int, str, str]:
    completed = subprocess.run(argv, text=True, capture_output=True, check=False)
    if check and completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise SystemExit(f"error: {' '.join(argv)} failed: {detail}")
    return completed.returncode, completed.stdout, completed.stderr


def rel(path: pathlib.Path) -> str:
    try:
        return str(path.relative_to(staging_root))
    except ValueError:
        return str(path)


def is_macho(path: pathlib.Path) -> bool:
    rc, stdout, _stderr = run(["file", "-b", "--mime-type", str(path)])
    return rc == 0 and "application/x-mach-binary" in stdout


def all_machos() -> list[pathlib.Path]:
    machos: list[pathlib.Path] = []
    for entry in staging_root.rglob("*"):
        if entry.is_symlink() or not entry.is_file():
            continue
        if is_macho(entry):
            machos.append(entry)
    return sorted(machos)


def parse_otool_path(line: str, field: str) -> str:
    return line.strip().removeprefix(field + " ").rsplit(" (", 1)[0]


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


def homebrew_rpaths(path: pathlib.Path) -> list[str]:
    rc, stdout, _stderr = run(["otool", "-arch", "all", "-l", str(path)])
    if rc != 0:
        return []
    rpaths: list[str] = []
    for lines in otool_sections(stdout.splitlines()):
        for index, raw_line in enumerate(lines):
            if raw_line.strip() != "cmd LC_RPATH":
                continue
            for candidate in lines[index + 1:index + 6]:
                if candidate.strip().startswith("path "):
                    rpath = parse_otool_path(candidate, "path")
                    if is_homebrew_openssl(str(pathlib.Path(rpath) / "libcrypto.3.dylib")) or is_homebrew_openssl(str(pathlib.Path(rpath) / "libssl.3.dylib")):
                        rpaths.append(rpath)
                    break
    return rpaths


def load_deps(path: pathlib.Path) -> list[tuple[str, pathlib.Path, Optional[str]]]:
    rc, stdout, _stderr = run(["otool", "-arch", "all", "-l", str(path)])
    if rc != 0:
        return []

    deps: list[tuple[str, pathlib.Path, Optional[str]]] = []
    load_commands = {
        "LC_LOAD_DYLIB",
        "LC_LOAD_WEAK_DYLIB",
        "LC_REEXPORT_DYLIB",
        "LC_LOAD_UPWARD_DYLIB",
        "LC_LAZY_LOAD_DYLIB",
    }
    for lines in otool_sections(stdout.splitlines()):
        rpaths: list[str] = []
        for index, raw_line in enumerate(lines):
            if raw_line.strip() != "cmd LC_RPATH":
                continue
            for candidate in lines[index + 1:index + 6]:
                if candidate.strip().startswith("path "):
                    rpaths.append(parse_otool_path(candidate, "path"))
                    break

        for index, raw_line in enumerate(lines):
            stripped = raw_line.strip()
            if not stripped.startswith("cmd "):
                continue
            if stripped.split(" ", 1)[1] not in load_commands:
                continue
            for candidate in lines[index + 1:index + 8]:
                if not candidate.strip().startswith("name "):
                    continue
                dep = parse_otool_path(candidate, "name")
                if is_homebrew_openssl(dep):
                    deps.append((dep, pathlib.Path(dep), None))
                elif dep.startswith("@rpath/"):
                    basename = pathlib.Path(dep).name
                    if (basename.startswith("libcrypto") or basename.startswith("libssl")) and basename.endswith(".dylib"):
                        for rpath in rpaths:
                            resolved = pathlib.Path(rpath) / dep.removeprefix("@rpath/")
                            if is_homebrew_openssl(str(resolved)) and resolved.is_file():
                                deps.append((dep, resolved, rpath))
                                break
                break
    return deps


def allowed_homebrew_prefixes() -> list[tuple[str, bool]]:
    prefixes = [("/opt/homebrew", False), ("/usr/local", False)]
    test_prefix = os.environ.get("ORCHARD_TEST_HOMEBREW_PREFIX")
    if test_prefix and os.environ.get("ORCHARD_ALLOW_TEST_HOMEBREW_PREFIX") == "1":
        prefixes.append((str(pathlib.Path(test_prefix).resolve()), True))
    return prefixes


def is_homebrew_openssl(dep: str) -> bool:
    path = pathlib.Path(dep)
    name = path.name
    if not (name.startswith("libcrypto") or name.startswith("libssl")) or not name.endswith(".dylib"):
        return False
    resolved_dep = str(path.resolve(strict=False))
    for prefix, test_only in allowed_homebrew_prefixes():
        raw_allowed = dep.startswith(prefix + "/opt/openssl@3/") or dep.startswith(prefix + "/Cellar/openssl@3/")
        resolved_allowed = resolved_dep.startswith(prefix + "/opt/openssl@3/") or resolved_dep.startswith(prefix + "/Cellar/openssl@3/")
        if test_only and resolved_allowed:
            return True
        if raw_allowed:
            return resolved_allowed
    if dep.startswith("/Users/") or dep.startswith("/private/var/") or dep.startswith("/var/folders/"):
        return False
    return False


def register_source(dep: str, source_path: pathlib.Path) -> None:
    source = source_path
    if not source.is_file():
        raise SystemExit(f"error: cannot bundle missing OpenSSL dylib referenced by OTP payload: {source}")
    dest = bundle_dir / source.name
    existing = source_to_dest.get(dep)
    if existing is not None:
        if source_paths[dep].read_bytes() != source.read_bytes():
            raise SystemExit(
                f"error: OpenSSL load token resolves to different dylib content: {dep} -> {source_paths[dep]} and {source}"
            )
        return
    for other_dep, other_dest in source_to_dest.items():
        if other_dest == dest and source_paths[other_dep].read_bytes() != source.read_bytes():
            raise SystemExit(
                f"error: OpenSSL dylib basename collision with different content: {source_paths[other_dep]} and {source} -> {dest.name}"
            )
    source_to_dest[dep] = dest
    source_paths[dep] = source


def relative_loader_ref(macho: pathlib.Path, target: pathlib.Path) -> str:
    relative = os.path.relpath(target, start=macho.parent)
    return "@loader_path/" + relative


def copy_registered_sources() -> bool:
    if not source_to_dest:
        return False
    bundle_dir.mkdir(parents=True, exist_ok=True)
    copied = False
    for dep, dest in list(source_to_dest.items()):
        source = source_paths[dep]
        if not dest.exists() or source.read_bytes() != dest.read_bytes():
            shutil.copy2(source, dest)
            dest.chmod(dest.stat().st_mode | 0o200)
            copied = True
    return copied


def discover_sources(machos: list[pathlib.Path]) -> None:
    index = 0
    while index < len(machos):
        macho = machos[index]
        for dep, source_path, _rpath in load_deps(macho):
            register_source(dep, source_path)
        copied = copy_registered_sources()
        if copied:
            for entry in sorted(bundle_dir.glob("*.dylib")):
                if entry not in machos and is_macho(entry):
                    machos.append(entry)
        index += 1


def rewrite_machos(machos: list[pathlib.Path]) -> None:
    for macho in machos:
        for dep, _source_path, rpath in load_deps(macho):
            dest = source_to_dest.get(dep)
            if dest is None:
                continue
            new_ref = relative_loader_ref(macho, dest)
            run(["install_name_tool", "-change", dep, new_ref, str(macho)], check=True)
            rewrites.append((macho, dep, new_ref))
            if rpath is not None and (macho, rpath) not in deleted_rpaths:
                run(["install_name_tool", "-delete_rpath", rpath, str(macho)], check=True)
                deleted_rpaths.add((macho, rpath))
        for rpath in homebrew_rpaths(macho):
            if (macho, rpath) not in deleted_rpaths:
                run(["install_name_tool", "-delete_rpath", rpath, str(macho)], check=True)
                deleted_rpaths.add((macho, rpath))

    for dest in sorted(set(source_to_dest.values())):
        if dest.exists():
            run(["install_name_tool", "-id", f"@rpath/{dest.name}", str(dest)], check=True)


def sha256(path: pathlib.Path) -> str:
    rc, stdout, stderr = run(["shasum", "-a", "256", str(path)])
    if rc != 0:
        raise SystemExit(f"error: shasum failed for {path}: {(stderr or stdout).strip()}")
    return stdout.split()[0]


def write_provenance() -> None:
    if not provenance_output:
        return
    output = pathlib.Path(provenance_output)
    output.parent.mkdir(parents=True, exist_ok=True)
    tmp_output = output.with_name(output.name + ".tmp")
    lines = ["# Orchard bundled OpenSSL provenance", f"staging_root={staging_root}", f"bundle_dir={rel(bundle_dir)}", ""]
    if not source_to_dest:
        lines.append("result=no_homebrew_openssl_load_commands_found")
    for dep, dest in source_to_dest.items():
        lines.append(f"source={source_paths[dep]}")
        lines.append(f"bundled={rel(dest)}")
        lines.append(f"sha256={sha256(dest)}")
        lines.append("")
    if rewrites:
        lines.append("# Rewritten load commands")
        for macho, old, new in rewrites:
            lines.append(f"rewrite={rel(macho)}\t{old}\t{new}")
    tmp_output.write_text("\n".join(lines).rstrip() + "\n")
    tmp_output.replace(output)


machos = all_machos()
discover_sources(machos)
if not source_to_dest:
    write_provenance()
    print("ok\tno Homebrew OpenSSL load commands found")
    sys.exit(0)

copy_registered_sources()
machos = all_machos()
rewrite_machos(machos)
write_provenance()
print(f"ok\tbundled {len(set(source_to_dest.values()))} OpenSSL dylib(s); rewrote {len(rewrites)} load command(s)")
PY
