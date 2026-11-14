from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


@pytest.mark.parametrize("use_venv", [True, False], ids=["direct-venv", "uv-fallback"])
def test_wrapper_preserves_controlled_cwd(tmp_path: Path, use_venv: bool) -> None:
    package = tmp_path / "package"
    (package / "bin").mkdir(parents=True)
    wrapper = package / "bin" / "orchard-tokenizer"
    shutil.copy2(Path(__file__).parents[1] / "bin" / "orchard-tokenizer", wrapper)
    (package / "pyproject.toml").write_text(
        '[project]\nname = "wrapper-probe"\nversion = "0.0.0"\n'
        'requires-python = ">=3.14"\n[tool.uv]\npackage = false\n'
    )
    executable_dir = package / ".venv" / "bin" if use_venv else tmp_path / "tools"
    executable_dir.mkdir(parents=True)
    probe = executable_dir / "orchard-tokenizer"
    probe.write_text('#!/bin/sh\npwd -P\nprintf "%s\\n" "$@"\n')
    probe.chmod(0o755)
    work = tmp_path / "work"
    work.mkdir(mode=0o700)
    uv = shutil.which("uv")
    assert uv is not None
    result = subprocess.run(
        [str(wrapper), "probe-argument"],
        cwd=work,
        env={
            "PATH": f"{executable_dir}:{Path(uv).parent}:/usr/bin:/bin",
            "HOME": str(work),
            "UV_PYTHON": str(Path(shutil.which("python3")).resolve()),
            "UV_NO_MANAGED_PYTHON": "1",
        },
        capture_output=True,
        text=True,
        check=True,
        timeout=15,
    )
    assert result.stdout.splitlines() == [str(work.resolve()), "probe-argument"]
