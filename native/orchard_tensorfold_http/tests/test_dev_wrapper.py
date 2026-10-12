"""SPEC.md 7.2.9: the source-dev wrapper adds only the experiment flag and profile."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

WRAPPER = Path(__file__).resolve().parents[1] / "bin" / "orchard-worker-tensorfold"


@pytest.fixture
def checkout(tmp_path):
    package = tmp_path / "native" / "orchard_tensorfold_http"
    (package / "bin").mkdir(parents=True)
    wrapper = package / "bin" / "orchard-worker-tensorfold"
    shutil.copy2(WRAPPER, wrapper)
    entry = package / ".venv" / "bin" / "orchard-worker-tensorfold"
    entry.parent.mkdir(parents=True)
    entry.write_text('#!/bin/sh\necho "pid=$$"\nfor arg in "$@"; do echo "arg=$arg"; done\n')
    entry.chmod(0o755)
    profile = tmp_path / "profile.json"
    profile.write_text("{}")
    return tmp_path, wrapper, entry, profile


def run(wrapper, env, *args):
    process = subprocess.Popen(
        [str(wrapper), *args],
        env={"PATH": os.environ["PATH"], **env},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    stdout, stderr = process.communicate(timeout=10)
    return process, stdout, stderr


def test_injects_experiment_flag_and_profile_and_keeps_node_arguments(checkout):
    _root, wrapper, _entry, profile = checkout
    process, stdout, _stderr = run(
        wrapper,
        {"ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE": str(profile)},
        "--socket-path",
        "/tmp/w.sock",
        "--backend",
        "tensorfold",
        "--log-file",
        "/tmp/worker log.txt",
    )
    assert process.returncode == 0
    lines = stdout.splitlines()
    # exec keeps the BEAM port's os_pid equal to the Python process.
    assert lines[0] == f"pid={process.pid}"
    assert [line.removeprefix("arg=") for line in lines[1:]] == [
        "--experimental-tensorfold",
        "--profile-file",
        str(profile),
        "--socket-path",
        "/tmp/w.sock",
        "--backend",
        "tensorfold",
        "--log-file",
        "/tmp/worker log.txt",
    ]


def test_relative_profile_resolves_from_the_checkout_root(checkout):
    root, wrapper, _entry, _profile = checkout
    process, stdout, _stderr = run(
        wrapper, {"ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE": "profile.json"}
    )
    assert process.returncode == 0
    assert f"arg={root.resolve() / 'profile.json'}" in stdout.splitlines()


@pytest.mark.parametrize("value", [None, "", "missing.json"])
def test_missing_profile_exits_64(checkout, value):
    _root, wrapper, _entry, _profile = checkout
    env = {} if value is None else {"ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE": value}
    process, stdout, stderr = run(wrapper, env)
    assert process.returncode == 64
    assert stdout == ""
    assert "ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE" in stderr


def test_missing_entrypoint_names_the_native_install(checkout):
    _root, wrapper, entry, profile = checkout
    entry.unlink()
    process, _stdout, stderr = run(
        wrapper, {"ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE": str(profile)}
    )
    assert process.returncode == 1
    assert "--extra native" in stderr
