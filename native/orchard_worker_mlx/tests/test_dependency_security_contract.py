"""Dependency security contract tests for the MLX worker."""

from __future__ import annotations

import tomllib
from pathlib import Path

_PACKAGE_ROOT = Path(__file__).resolve().parents[1]
_PYPROJECT = _PACKAGE_ROOT / "pyproject.toml"
_LOCKFILE = _PACKAGE_ROOT / "uv.lock"
_MLX_LM_COMMIT = "ab1806e8f5d6aa035973af194a1b9198ab4754dc"
_MLX_LM_GIT = "https://github.com/ml-explore/mlx-lm.git"


def _read_toml(path: Path) -> dict:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def _packages_named(lock: dict, name: str) -> list[dict]:
    return [package for package in lock["package"] if package["name"] == name]


def test_mlx_extra_uses_the_approved_source_and_transformers_range() -> None:
    project = _read_toml(_PYPROJECT)

    assert project["project"]["optional-dependencies"]["mlx"] == [
        "mlx>=0.31.2",
        "mlx-lm==0.31.3",
        "transformers>=5.7,<5.13",
        "protobuf>=6.33.5",
        "numpy>=1.26.0",
    ]
    assert project["tool"]["uv"]["sources"]["mlx-lm"] == {
        "git": _MLX_LM_GIT,
        "rev": _MLX_LM_COMMIT,
    }


def test_lock_resolves_the_approved_mlx_lm_commit() -> None:
    lock = _read_toml(_LOCKFILE)
    packages = _packages_named(lock, "mlx-lm")

    assert len(packages) == 1
    package = packages[0]
    assert package["version"] == "0.31.3"
    source = package["source"]
    assert "registry" not in source
    assert source["git"].startswith(f"{_MLX_LM_GIT}?rev={_MLX_LM_COMMIT}")
    assert source["git"].endswith(f"#{_MLX_LM_COMMIT}")

    project_package = _packages_named(lock, "orchard-worker-mlx")
    assert len(project_package) == 1
    requirements = project_package[0]["metadata"]["requires-dist"]
    assert {
        "name": "mlx-lm",
        "marker": "extra == 'mlx'",
        "git": f"{_MLX_LM_GIT}?rev={_MLX_LM_COMMIT}",
    } in requirements
    assert {
        "name": "transformers",
        "marker": "extra == 'mlx'",
        "specifier": ">=5.7,<5.13",
    } in requirements


def test_lock_keeps_transformers_in_the_approved_hashed_registry_range() -> None:
    lock = _read_toml(_LOCKFILE)
    packages = _packages_named(lock, "transformers")

    assert len(packages) == 1
    package = packages[0]
    major, minor, *_ = (int(part) for part in package["version"].split("."))
    assert major == 5
    assert 7 <= minor < 13
    assert package["source"]["registry"] == "https://pypi.org/simple"
    assert package["sdist"]["url"].startswith("https://files.pythonhosted.org/")
    assert package["sdist"]["hash"].startswith("sha256:")
    assert package["sdist"]["size"] > 0
    assert package["wheels"]
    assert all(
        wheel["url"].startswith("https://files.pythonhosted.org/") for wheel in package["wheels"]
    )
    assert all(wheel["hash"].startswith("sha256:") for wheel in package["wheels"])
    assert all(wheel["size"] > 0 for wheel in package["wheels"])
