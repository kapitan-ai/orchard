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

native_root = pathlib.Path(sys.argv[1])
def copy_without_metadata(src: pathlib.Path, dst: pathlib.Path) -> pathlib.Path:
    shutil.copyfile(src, dst)
    shutil.copymode(src, dst, follow_symlinks=False)
    return dst


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
        if not text.startswith("#!"):
            continue
        first, sep, rest = text.partition("\n")
        if "python" not in first:
            continue
        launcher = "#!/bin/sh\n'''exec' \"$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)/python\" \"$0\" \"$@\"\n' '''"
        script.write_text(launcher + (sep + rest if sep else "\n"))
        os.chmod(script, mode)

    cfg = venv / "pyvenv.cfg"
    if cfg.exists():
        lines = [line for line in cfg.read_text().splitlines() if not line.startswith("home = ")]
        cfg.write_text("\n".join(lines) + "\n")

    print(f"materialized\t{venv}")
PY
