from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).parents[3] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import kap112_build_fixture_bundle as bundle_builder  # noqa: E402
import kap112_verify_hf_snapshot as snapshot_verifier  # noqa: E402


def test_snapshot_manifest_reconciles_selected_files_not_repository_storage() -> None:
    manifest = json.loads(snapshot_verifier.SNAPSHOT_MANIFEST_PATH.read_text())
    files = manifest["files"]

    assert manifest["file_count"] == len(files) == 32
    assert manifest["total_bytes"] == sum(item["size"] for item in files) == 55_586_114_863
    assert sum(item["size"] for item in files if item["lfs_sha256"]) == 55_575_816_096
    assert sum(item["size"] for item in files if not item["lfs_sha256"]) == 10_298_767
    assert 55_575_816_096 + 40_059_589 == 55_615_875_685
    assert 40_059_589 - 10_298_767 == 29_760_822
    assert sum(item["path"].endswith(".safetensors") for item in files) == 18
    assert all(item["etag"] == (item["lfs_sha256"] or item["blob_id"]) for item in files)
    assert all(item["path"] != "R.Basca_Tr2.geojson" for item in files)


def _snapshot_evidence(snapshot: Path, evidence: Path) -> int:
    files = []
    total = 0
    for path in sorted(snapshot.rglob("*")):
        if not path.is_file():
            continue
        size = path.stat().st_size
        total += size
        files.append(
            {
                "path": path.relative_to(snapshot).as_posix(),
                "size": size,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "git_blob_sha1": None,
            }
        )
    evidence.write_text(
        json.dumps(
            {
                "model_id": snapshot_verifier.MODEL_ID,
                "revision": snapshot_verifier.REVISION,
                "total_bytes": total,
                "files": files,
            }
        )
    )
    return total


def _snapshot_contract(
    evidence_path: Path, contract_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    evidence = json.loads(evidence_path.read_text())
    files = [
        {
            "path": item["path"],
            "size": item["size"],
            "blob_id": item["git_blob_sha1"] or "lfs-pointer",
            "lfs_sha256": item["sha256"],
            "etag": item["sha256"] or item["git_blob_sha1"],
        }
        for item in evidence["files"]
    ]
    contract_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "model_id": snapshot_verifier.MODEL_ID,
                "revision": snapshot_verifier.REVISION,
                "total_bytes": evidence["total_bytes"],
                "file_count": len(files),
                "files": files,
            }
        )
    )
    monkeypatch.setattr(snapshot_verifier, "SNAPSHOT_MANIFEST_PATH", contract_path)


def test_builds_proof_only_bundle_from_exact_snapshot_assets(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    snapshot = tmp_path / "snapshot"
    evidence_path = tmp_path / "evidence.json"
    bundle = tmp_path / "bundle"
    snapshot.mkdir()
    (snapshot / "tokenizer.json").write_text('{"version":"1.0"}\n')
    (snapshot / "tokenizer_config.json").write_text(json.dumps({"chat_template": "{{ messages }}"}))
    monkeypatch.setattr(
        bundle_builder,
        "CHAT_TEMPLATE_SHA256",
        hashlib.sha256(b"{{ messages }}").hexdigest(),
    )
    total = _snapshot_evidence(snapshot, evidence_path)
    monkeypatch.setattr(snapshot_verifier, "EXPECTED_BYTES", total)
    _snapshot_contract(evidence_path, tmp_path / "contract.json", monkeypatch)
    monkeypatch.setattr(
        sys,
        "argv",
        ["kap112_build_fixture_bundle.py", str(snapshot), str(evidence_path), str(bundle)],
    )
    assert bundle_builder.main() == 0

    summary = json.loads(capsys.readouterr().out)
    manifest = json.loads((bundle / "manifest.json").read_text())
    evidence = json.loads((bundle / "tool_capability_evidence.json").read_text())
    reasoning_contract = json.loads((bundle / "reasoning_contract_template.json").read_text())
    derived_config = (bundle / "tokenizer_config.json").read_bytes()
    assert summary["proof_only"] is True
    assert manifest["model_id"] == "Qwen/Qwen3.8-27B"
    assert manifest["version"] == "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
    assert manifest["max_context_tokens"] == 139_264
    assert manifest["runtime_requirements"] == {
        "adapter": "vllm_poc",
        "min_agent_capability": "kap112_unmanaged_linux_poc",
    }
    assert evidence["tool_calling"]["runtime_qualification"] == "not_established"
    assert reasoning_contract["reasoning_effort"] == "medium"
    assert reasoning_contract["sampling"]["temperature"] == 1.0
    assert "runtime_parser" not in evidence["tool_calling"]
    assert (
        evidence["tool_calling"]["tokenizer_config_sha256"]
        == hashlib.sha256(derived_config).hexdigest()
    )
    assert json.loads(derived_config)["tool_parser_type"] == "qwen2"
    assert (bundle / "weights" / "PROOF_ONLY_PROVIDER_OWNS_WEIGHTS").is_file()


def test_refuses_existing_bundle_destination(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    snapshot = tmp_path / "snapshot"
    bundle = tmp_path / "bundle"
    snapshot.mkdir()
    bundle.mkdir()
    monkeypatch.setattr(
        sys,
        "argv",
        ["kap112_build_fixture_bundle.py", str(snapshot), str(tmp_path / "evidence"), str(bundle)],
    )
    with pytest.raises(SystemExit, match="destination must be absent"):
        bundle_builder.main()


def test_snapshot_verification_rejects_tampering_and_extra_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    snapshot = tmp_path / "snapshot"
    evidence = tmp_path / "evidence.json"
    snapshot.mkdir()
    protected = snapshot / "tokenizer.json"
    protected.write_text("original")
    total = _snapshot_evidence(snapshot, evidence)
    monkeypatch.setattr(snapshot_verifier, "EXPECTED_BYTES", total)
    _snapshot_contract(evidence, tmp_path / "contract.json", monkeypatch)
    snapshot_verifier.verify_snapshot(snapshot, evidence)

    protected.write_text("tampered")
    with pytest.raises(SystemExit, match="size mismatch|SHA-256 mismatch"):
        snapshot_verifier.verify_snapshot(snapshot, evidence)
    _snapshot_evidence(snapshot, evidence)
    with pytest.raises(SystemExit, match="contract manifest"):
        snapshot_verifier.verify_snapshot(snapshot, evidence)

    protected.write_text("original")
    _snapshot_evidence(snapshot, evidence)
    (snapshot / "unrecorded.json").write_text("{}")
    with pytest.raises(SystemExit, match="inventory drifted"):
        snapshot_verifier.verify_snapshot(snapshot, evidence)
