from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

MODEL_ID = "Qwen/Qwen3.8-27B"
REVISION = "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
EXPECTED_BYTES = 55_586_114_863
SNAPSHOT_MANIFEST_PATH = Path(__file__).parent / "fixtures/kap112/qwen-snapshot-manifest.json"
DOWNLOAD_INTERPRETER = "/usr/bin/python3.12"
DOWNLOAD_INTERPRETER_VERSION = (3, 12, 13)
DOWNLOAD_INTERPRETER_SHA256 = "185be5c01624944b5c422a8d1e4995a7df010036a99c9f9d84a80a09ae1bd72d"
HUGGINGFACE_HUB_VERSION = "1.27.0"


def _metadata_value(value: Any, key: str) -> Any:
    if isinstance(value, dict):
        return value.get(key)
    return getattr(value, key, None)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _git_blob_sha1(path: Path) -> str:
    digest = hashlib.sha1(usedforsecurity=False)
    digest.update(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _snapshot_manifest() -> dict[str, Any]:
    try:
        manifest = json.loads(SNAPSHOT_MANIFEST_PATH.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise SystemExit("snapshot contract manifest is unreadable or invalid") from None
    files = manifest.get("files") if isinstance(manifest, dict) else None
    if (
        not isinstance(manifest, dict)
        or not isinstance(files, list)
        or not all(isinstance(item, dict) for item in files)
        or manifest.get("schema_version") != 1
        or manifest.get("model_id") != MODEL_ID
        or manifest.get("revision") != REVISION
        or manifest.get("total_bytes") != EXPECTED_BYTES
        or manifest.get("file_count") != len(files)
        or sum(item.get("size", -1) for item in files) != EXPECTED_BYTES
    ):
        raise SystemExit("snapshot contract manifest identity drifted")
    return manifest


def _evidence_files(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "path": item["path"],
            "size": item["size"],
            "sha256": item["lfs_sha256"],
            "git_blob_sha1": None if item["lfs_sha256"] else item["blob_id"],
        }
        for item in manifest["files"]
    ]


def verify_snapshot(snapshot_dir: Path, evidence_path: Path) -> None:
    try:
        evidence = json.loads(evidence_path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise SystemExit("snapshot evidence is unreadable or invalid") from None
    if not isinstance(evidence, dict):
        raise SystemExit("snapshot evidence must be an object")
    if (
        evidence.get("model_id") != MODEL_ID
        or evidence.get("revision") != REVISION
        or evidence.get("total_bytes") != EXPECTED_BYTES
        or not isinstance(evidence.get("files"), list)
    ):
        raise SystemExit("snapshot evidence identity drifted")
    contract = _snapshot_manifest()
    if evidence["files"] != _evidence_files(contract):
        raise SystemExit("snapshot evidence drifted from the contract manifest")

    expected_paths: set[str] = set()
    expected_total = 0
    for item in evidence["files"]:
        if not isinstance(item, dict):
            raise SystemExit("snapshot evidence file entry is invalid")
        relative = item.get("path")
        size = item.get("size")
        sha256 = item.get("sha256")
        git_blob_sha1 = item.get("git_blob_sha1")
        path = Path(relative) if isinstance(relative, str) else Path("/")
        if (
            not isinstance(relative, str)
            or not relative
            or path.is_absolute()
            or ".." in path.parts
            or relative in expected_paths
            or isinstance(size, bool)
            or not isinstance(size, int)
            or size < 0
            or (not isinstance(sha256, str) and not isinstance(git_blob_sha1, str))
        ):
            raise SystemExit("snapshot evidence file entry is invalid")
        expected_paths.add(relative)
        expected_total += size
        actual = snapshot_dir / path
        if actual.is_symlink() or not actual.is_file() or actual.stat().st_size != size:
            raise SystemExit(f"snapshot file size mismatch: {relative}")
        if isinstance(sha256, str):
            if _sha256(actual) != sha256:
                raise SystemExit(f"snapshot SHA-256 mismatch: {relative}")
        elif _git_blob_sha1(actual) != git_blob_sha1:
            raise SystemExit(f"snapshot Git blob mismatch: {relative}")

    if expected_total != EXPECTED_BYTES:
        raise SystemExit("snapshot evidence file total drifted")
    actual_paths = {
        path.relative_to(snapshot_dir).as_posix()
        for path in snapshot_dir.rglob("*")
        if path.is_file() and ".cache" not in path.relative_to(snapshot_dir).parts
    }
    if actual_paths != expected_paths:
        raise SystemExit("snapshot file inventory drifted")


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--verify":
        verify_snapshot(Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve())
        print(json.dumps({"snapshot_verified": True}, sort_keys=True))
        return 0
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: kap112_verify_hf_snapshot.py SNAPSHOT_DIR EVIDENCE_JSON | "
            "kap112_verify_hf_snapshot.py --verify SNAPSHOT_DIR EVIDENCE_JSON"
        )

    snapshot_dir = Path(sys.argv[1]).resolve()
    evidence_path = Path(sys.argv[2]).resolve()
    if snapshot_dir.exists() or evidence_path.exists():
        raise SystemExit("snapshot and evidence destinations must not already exist")
    snapshot_dir.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.parent.mkdir(parents=True, exist_ok=True)

    import huggingface_hub
    from huggingface_hub import HfApi, get_hf_file_metadata, hf_hub_url, snapshot_download

    if (
        sys.executable != DOWNLOAD_INTERPRETER
        or sys.version_info[:3] != DOWNLOAD_INTERPRETER_VERSION
        or _sha256(Path(sys.executable)) != DOWNLOAD_INTERPRETER_SHA256
        or huggingface_hub.__version__ != HUGGINGFACE_HUB_VERSION
    ):
        raise SystemExit("snapshot download interpreter identity drifted")

    api = HfApi(token=os.environ.get("HF_TOKEN"))
    info = api.model_info(MODEL_ID, revision=REVISION, files_metadata=True)
    if info.sha != REVISION:
        raise SystemExit("resolved model revision drifted")

    contract = _snapshot_manifest()
    observed: list[dict[str, Any]] = []
    for sibling in sorted(info.siblings, key=lambda item: item.rfilename):
        path = sibling.rfilename
        size = sibling.size
        if not isinstance(path, str) or not isinstance(size, int) or size < 0:
            raise SystemExit("Hub returned incomplete file metadata")
        lfs_sha256 = _metadata_value(sibling.lfs, "sha256")
        metadata = get_hf_file_metadata(hf_hub_url(MODEL_ID, path, revision=REVISION))
        observed.append(
            {
                "path": path,
                "size": size,
                "blob_id": sibling.blob_id,
                "lfs_sha256": lfs_sha256,
                "etag": metadata.etag,
            }
        )

    if observed != contract["files"]:
        raise SystemExit("immutable Hub file manifest drifted")
    expected = _evidence_files(contract)

    total_bytes = sum(item["size"] for item in expected)
    if total_bytes != EXPECTED_BYTES:
        raise SystemExit(
            f"model repository byte total drifted: expected {EXPECTED_BYTES}, got {total_bytes}"
        )

    downloaded = Path(
        snapshot_download(
            repo_id=MODEL_ID,
            revision=REVISION,
            local_dir=snapshot_dir,
            token=os.environ.get("HF_TOKEN"),
        )
    ).resolve()
    if downloaded != snapshot_dir:
        raise SystemExit("snapshot download returned an unexpected destination")

    for item in expected:
        path = snapshot_dir / item["path"]
        if not path.is_file() or path.stat().st_size != item["size"]:
            raise SystemExit(f"snapshot file size mismatch: {item['path']}")
        if item["sha256"]:
            if _sha256(path) != item["sha256"]:
                raise SystemExit(f"snapshot SHA-256 mismatch: {item['path']}")
        elif not item["git_blob_sha1"] or _git_blob_sha1(path) != item["git_blob_sha1"]:
            raise SystemExit(f"snapshot Git blob mismatch: {item['path']}")

    evidence_path.write_text(
        json.dumps(
            {
                "model_id": MODEL_ID,
                "revision": REVISION,
                "total_bytes": total_bytes,
                "files": expected,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    )
    evidence_path.chmod(0o600)
    verify_snapshot(snapshot_dir, evidence_path)
    print(
        json.dumps(
            {
                "model_id": MODEL_ID,
                "revision": REVISION,
                "total_bytes": total_bytes,
                "file_count": len(expected),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
