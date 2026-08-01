#!/bin/bash
#
# Verify Orchard staged or expanded PKG payload Mach-O dependency closure.
# Usage: scripts/verify-staged-venv-closure.sh [--no-smoke] [--forbid-path <path>]... <staging-or-expanded-root>
#
# --forbid-path names an extra build-host root (for example the repo checkout) that
# staged pyvenv.cfg and bin/ launcher contents must not reference; repeat per root.

set -euo pipefail

usage() {
    echo "Usage: $0 [--no-smoke] [--forbid-path <path>]... <staging-or-expanded-root>" >&2
}

RUN_SMOKE=true
FORBIDDEN_ROOTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-smoke)
            RUN_SMOKE=false
            shift
            ;;
        --forbid-path)
            if [[ $# -lt 2 ]]; then
                usage
                exit 64
            fi
            FORBIDDEN_ROOTS+=("$2")
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

ROOT="$1"
if [[ ! -d "$ROOT" ]]; then
    echo "error: payload root does not exist: $ROOT" >&2
    exit 66
fi

for required in python3 file otool; do
    if ! command -v "$required" >/dev/null 2>&1; then
        echo "error: $required is required but was not found on PATH" >&2
        exit 69
    fi
done

python3 - "$ROOT" "$RUN_SMOKE" "${FORBIDDEN_ROOTS[@]:-}" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
from typing import Optional

root = pathlib.Path(sys.argv[1]).resolve()
run_smoke = sys.argv[2] == "true"


def forbidden_root_variants(values: list[str]) -> tuple[str, ...]:
    variants: list[str] = []
    for value in values:
        if not value:
            continue
        candidate = pathlib.Path(value)
        for form in (str(candidate), str(candidate.resolve(strict=False))):
            if form not in variants:
                variants.append(form)
    return tuple(variants)


forbidden_roots = forbidden_root_variants(sys.argv[3:])
payload_rel = pathlib.Path("Library/Application Support/Orchard")
install_prefix = pathlib.Path("/Library/Application Support/Orchard")
allowed_system_prefixes = ("/usr/lib/", "/System/Library/")
forbidden_path_fragments = (
    "/opt/homebrew/",
    "/usr/local/opt/",
    "/Cellar/",
    "/Users/",
    "/private/var/",
    "/var/folders/",
)
forbidden_cfg_fragments = forbidden_path_fragments + (".local/share/uv",) + forbidden_roots
forbidden_launcher_fragments = forbidden_cfg_fragments + (".venv-pkg", str(root))
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


def discover_machos() -> list[pathlib.Path]:
    machos: list[pathlib.Path] = []
    for entry in root.rglob("*"):
        if entry.is_symlink() or not entry.is_file():
            continue
        if is_macho(entry):
            machos.append(entry)
    return sorted(machos)


def strip_otool_path(value: str, field: str) -> str:
    return value.removeprefix(field + " ").rsplit(" (", 1)[0]


def has_forbidden_fragment(value: str) -> Optional[str]:
    normalized = value.replace("//", "/")
    for fragment in forbidden_path_fragments:
        if fragment in normalized:
            return fragment
    if normalized.startswith("/opt/homebrew/"):
        return "/opt/homebrew/"
    if normalized.startswith("/usr/local/opt/"):
        return "/usr/local/opt/"
    return None


def is_system_path(path: pathlib.Path) -> bool:
    return str(path).startswith(allowed_system_prefixes)


def is_in_root(path: pathlib.Path) -> bool:
    resolved = path.resolve(strict=False)
    return str(resolved) == str(root) or str(resolved).startswith(str(root) + os.sep)


def is_within(path: pathlib.Path, base: pathlib.Path) -> bool:
    resolved = path.resolve(strict=False)
    base_resolved = base.resolve(strict=False)
    return str(resolved) == str(base_resolved) or str(resolved).startswith(str(base_resolved) + os.sep)


def product_roots() -> list[pathlib.Path]:
    roots: list[pathlib.Path] = []
    for candidate in [root / payload_rel, root / "Payload" / payload_rel]:
        if candidate.exists():
            roots.append(candidate)
    if root.name == "Orchard" and root.parent.name == "Application Support" and root.parent.parent.name == "Library":
        roots.append(root)
    if all((root / component).is_dir() for component in ("releases", "native", "share")):
        roots.append(root)
    return roots


orchard_product_roots = product_roots()


def payload_candidates(install_relative: pathlib.Path) -> list[pathlib.Path]:
    return [product_root / install_relative for product_root in orchard_product_roots]


def map_install_prefix(path: pathlib.Path) -> Optional[pathlib.Path]:
    try:
        install_relative = path.relative_to(install_prefix)
    except ValueError:
        return None

    if ".." in install_relative.parts:
        return None

    candidates = payload_candidates(install_relative)
    for candidate in candidates:
        if candidate.exists() and is_in_root(candidate):
            return candidate
    return candidates[0]


def is_payload_path(path: pathlib.Path) -> bool:
    if any(is_within(path, product_root) for product_root in orchard_product_roots):
        return True
    mapped = map_install_prefix(path) if path.is_absolute() else None
    return mapped is not None and mapped.exists() and any(is_within(mapped, product_root) for product_root in orchard_product_roots)


def allowed_existing_path(path: pathlib.Path) -> bool:
    return is_system_path(path) or is_payload_path(path)


def raw_absolute_rpath_allowed(token: str) -> bool:
    if not token.startswith("/"):
        return True
    token_path = pathlib.Path(token)
    return is_system_path(token_path) or map_install_prefix(token_path) is not None


def expand_macho_path(
    token: str,
    macho: pathlib.Path,
    executable_dir: Optional[pathlib.Path],
    rpath: Optional[pathlib.Path] = None,
) -> Optional[pathlib.Path]:
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
    if token.startswith("@rpath/") and rpath is not None:
        return rpath / token.removeprefix("@rpath/")
    if token.startswith("/"):
        return pathlib.Path(token)
    return None


def normalize_expanded_path(path: pathlib.Path) -> pathlib.Path:
    mapped = map_install_prefix(path) if path.is_absolute() else None
    return (mapped if mapped is not None else path).resolve(strict=False)


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


def parse_macho_loads(macho: pathlib.Path, executable_dir: Optional[pathlib.Path]) -> list[tuple[list[pathlib.Path], list[str]]]:
    rc, stdout, stderr = command_stdout(["otool", "-arch", "all", "-l", str(macho)])
    if rc != 0:
        errors.append(f"otool -l failed: {rel(macho)}: {stderr.strip()}")
        return []

    parsed: list[tuple[list[pathlib.Path], list[str]]] = []
    load_commands = {
        "LC_LOAD_DYLIB",
        "LC_LOAD_WEAK_DYLIB",
        "LC_REEXPORT_DYLIB",
        "LC_LOAD_UPWARD_DYLIB",
        "LC_LAZY_LOAD_DYLIB",
    }
    for lines in otool_sections(stdout.splitlines()):
        rpaths: list[pathlib.Path] = []
        deps: list[str] = []
        for index, line in enumerate(lines):
            stripped = line.strip()
            if stripped != "cmd LC_RPATH":
                continue
            for candidate in lines[index + 1:index + 6]:
                candidate = candidate.strip()
                if not candidate.startswith("path "):
                    continue
                rpath_token = strip_otool_path(candidate, "path")
                expanded = expand_macho_path(rpath_token, macho, executable_dir)
                if expanded is None:
                    errors.append(f"unresolved LC_RPATH: {rel(macho)} -> {rpath_token}")
                    continue
                forbidden = has_forbidden_fragment(rpath_token)
                if forbidden is not None:
                    errors.append(f"forbidden LC_RPATH: {rel(macho)} -> {rpath_token} ({forbidden})")
                    continue
                if not raw_absolute_rpath_allowed(rpath_token):
                    errors.append(f"outbound LC_RPATH: {rel(macho)} -> {rpath_token}")
                    continue
                normalized = normalize_expanded_path(expanded)
                if normalized.is_absolute() and not allowed_existing_path(normalized):
                    errors.append(f"outbound LC_RPATH: {rel(macho)} -> {rpath_token} -> {normalized}")
                    continue
                rpaths.append(normalized)
                break
        for index, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith("cmd ") and stripped.split(" ", 1)[1] in load_commands:
                for candidate in lines[index + 1:index + 8]:
                    candidate = candidate.strip()
                    if not candidate.startswith("name "):
                        continue
                    deps.append(strip_otool_path(candidate, "name"))
                    break
        parsed.append((rpaths, deps))
    return parsed


def verify_dependency(macho: pathlib.Path, executable_dir: Optional[pathlib.Path], rpaths: list[pathlib.Path], dep: str) -> None:
    forbidden = has_forbidden_fragment(dep)
    if forbidden is not None:
        errors.append(f"forbidden Mach-O dependency: {rel(macho)} -> {dep} ({forbidden})")
        return

    if dep.startswith(allowed_system_prefixes):
        return

    if dep.startswith(("@loader_path/", "@executable_path/")):
        resolved = expand_macho_path(dep, macho, executable_dir)
        resolved = normalize_expanded_path(resolved) if resolved is not None else None
        if resolved is None or not resolved.exists():
            errors.append(f"unresolved Mach-O dependency: {rel(macho)} -> {dep}")
        elif not allowed_existing_path(resolved):
            errors.append(f"outbound Mach-O dependency: {rel(macho)} -> {dep} -> {resolved}")
        return

    if dep.startswith("@rpath/"):
        candidates = [expand_macho_path(dep, macho, executable_dir, rpath) for rpath in rpaths]
        resolved_candidates = [normalize_expanded_path(candidate) for candidate in candidates if candidate is not None]
        if not any(candidate.exists() and allowed_existing_path(candidate) for candidate in resolved_candidates):
            detail = ", ".join(str(candidate) for candidate in resolved_candidates) or "no LC_RPATH"
            errors.append(f"unresolved @rpath dependency: {rel(macho)} -> {dep} ({detail})")
        return

    if dep.startswith("/"):
        dep_path = pathlib.Path(dep)
        mapped = map_install_prefix(dep_path)
        if is_system_path(dep_path):
            return
        if mapped is not None and mapped.exists() and allowed_existing_path(mapped):
            return
        errors.append(f"outbound Mach-O dependency: {rel(macho)} -> {dep}")
        return

    errors.append(f"unresolved Mach-O dependency: {rel(macho)} -> {dep}")


known_native_helpers = {
    "orchard_tokenizer": {"pkg": "orchard_tokenizer", "entry": "orchard-tokenizer"},
    "orchard_worker_mlx": {"pkg": "orchard_worker_mlx", "entry": "orchard-worker-mlx"},
}


def detail_from(completed: subprocess.CompletedProcess[str]) -> str:
    return (completed.stderr or completed.stdout).strip()


def site_packages_dirs(venv: pathlib.Path) -> list[pathlib.Path]:
    return sorted(path for path in (venv / "lib").glob("python*/site-packages") if path.is_dir())


def orchard_editable_pth(pth: pathlib.Path, pkg: str) -> bool:
    if pth.name.startswith("_editable_impl_orchard_"):
        return True
    text = pth.read_text(errors="replace")
    if "_editable_impl_orchard_" in text or (pkg in text and "editable" in text.lower()):
        return True
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if f"native/{pkg}/src" in stripped or f"native/{pkg.replace('_', '-')}/src" in stripped:
            return True
        if stripped.endswith(f"/{pkg}/src") or stripped.endswith(f"/{pkg.replace('_', '-')}/src"):
            return True
    return False


default_smoke_timeout = 10
tokenizer_preflight_timeout = 180


def run_smoke_command(
    args: list[str],
    env: dict[str, str],
    timeout_label: str,
    timeout_seconds: int = default_smoke_timeout,
) -> Optional[subprocess.CompletedProcess[str]]:
    try:
        return subprocess.run(
            args,
            text=True,
            capture_output=True,
            check=False,
            env=env,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        errors.append(f"{timeout_label} timed out after {timeout_seconds}s")
        return None


def verify_tokenizer_safe_preflight(python: pathlib.Path, entry: pathlib.Path, env: dict[str, str]) -> None:
    with tempfile.TemporaryDirectory(prefix="orchard-tokenizer-installed-smoke-") as temp_dir:
        bundle = pathlib.Path(temp_dir)
        generator = """
import pathlib
import sys
from tokenizers import Tokenizer
from tokenizers.decoders import ByteLevel as ByteLevelDecoder
from tokenizers.models import BPE
from tokenizers.pre_tokenizers import ByteLevel
from tokenizers.trainers import BpeTrainer

root = pathlib.Path(sys.argv[1])
corpus = root / "corpus.txt"
corpus.write_text("hello orchard user assistant system lookup weather", encoding="utf-8")
tokenizer = Tokenizer(BPE(unk_token="<unk>"))
tokenizer.pre_tokenizer = ByteLevel(add_prefix_space=False)
tokenizer.decoder = ByteLevelDecoder()
trainer = BpeTrainer(
    vocab_size=300,
    initial_alphabet=ByteLevel.alphabet(),
    special_tokens=["<unk>", "<|im_end|>", "<|im_start|>"],
)
tokenizer.train([str(corpus)], trainer)
tokenizer.save(str(root / "tokenizer.json"))
(root / "tokenizer_config.json").write_text("{}", encoding="utf-8")
(root / "chat_template.jinja").write_text(
    "<|im_start|>{{ messages[0]['role'] }}\\n{{ messages[0]['content'] }}\\n<|im_end|>",
    encoding="utf-8",
)
"""
        generated = run_smoke_command(
            [str(python), "-c", generator, str(bundle)],
            env,
            f"installed tokenizer smoke fixture generation failed: {rel(python)}",
            tokenizer_preflight_timeout,
        )
        if generated is None:
            return
        if generated.returncode != 0:
            errors.append(
                f"installed tokenizer smoke fixture generation failed: {rel(python)}: {detail_from(generated)}"
            )
            return

        control_tokens = ["<|im_end|>", "<|im_start|>"]
        payload = {
            "contract_version": 3,
            "command": "preflight_safe_tokenization",
            "assets": {
                "tokenizer_kind": "huggingface_tokenizer_json",
                "tokenizer_path": str(bundle / "tokenizer.json"),
                "tokenizer_config_path": str(bundle / "tokenizer_config.json"),
                "chat_template_path": str(bundle / "chat_template.jinja"),
            },
            "safe_tokenization": {
                "control_tokens": control_tokens,
                "catalog_sha256": hashlib.sha256("\0".join(control_tokens).encode("utf-8")).hexdigest(),
            },
        }
        preflight = run_smoke_command(
            [str(entry), "--request-json", json.dumps(payload)],
            env,
            f"installed tokenizer safe-tokenization preflight smoke failed: {rel(entry)}",
            tokenizer_preflight_timeout,
        )
        if preflight is None:
            return
        try:
            response = json.loads(preflight.stdout)
        except json.JSONDecodeError:
            response = None
        result = response.get("result") if isinstance(response, dict) else None
        if (
            preflight.returncode != 0
            or not isinstance(response, dict)
            or response.get("ok") is not True
            or not isinstance(result, dict)
            or result.get("compatible") is not True
        ):
            errors.append(
                "installed tokenizer safe-tokenization preflight smoke failed: "
                f"{rel(entry)}: {detail_from(preflight) or preflight.stdout.strip() or 'invalid response'}"
            )


def verify_known_helper_static(venv: pathlib.Path, helper: dict[str, str]) -> pathlib.Path:
    entry = venv / "bin" / helper["entry"]
    if not entry.is_file() or not os.access(entry, os.X_OK):
        errors.append(f"expected entrypoint missing or not executable: {rel(entry)}")

    pkg = helper["pkg"]
    site_packages_roots = site_packages_dirs(venv)
    if not site_packages_roots:
        errors.append(f"site-packages directory missing from staged venv: {rel(venv)}")
    elif not any((site_packages / pkg / "__init__.py").is_file() for site_packages in site_packages_roots):
        errors.append(f"{pkg} package __init__.py missing from staged venv site-packages: {rel(venv)}")

    for site_packages in site_packages_roots:
        for pth in sorted(site_packages.glob("*.pth")):
            if orchard_editable_pth(pth, helper["pkg"]):
                errors.append(
                    "Orchard editable .pth present in staged venv "
                    f"(packaging must be non-editable): {rel(pth)}"
                )
    return entry


def verify_known_helper_smoke(venv: pathlib.Path, python: pathlib.Path, entry: pathlib.Path, helper: dict[str, str]) -> None:
    env = {"PATH": "/usr/bin:/bin", "HOME": "/tmp"}
    pkg = helper["pkg"]
    import_smoke = run_smoke_command(
        [str(python), "-c", f"import {pkg}, {pkg}.cli; print({pkg}.__file__)"],
        env,
        f"{pkg} package import smoke failed: {rel(python)}",
    )
    if import_smoke is not None and import_smoke.returncode != 0:
        errors.append(f"{pkg} package not importable: {rel(python)}: {detail_from(import_smoke)}")

    if entry.is_file() and os.access(entry, os.X_OK):
        entry_smoke = run_smoke_command(
            [str(entry), "--help"],
            env,
            f"{helper['entry']} entrypoint smoke failed: {rel(entry)}",
        )
        if entry_smoke is not None and entry_smoke.returncode != 0:
            errors.append(f"{helper['entry']} entrypoint smoke failed: {rel(entry)}: {detail_from(entry_smoke)}")
        if pkg == "orchard_tokenizer":
            verify_tokenizer_safe_preflight(python, entry, env)


def verify_venv(venv: pathlib.Path) -> None:
    venv_real = venv.resolve(strict=False)
    python = venv / "bin" / "python"
    known_helper = known_native_helpers.get(venv.parent.name)
    known_entry = verify_known_helper_static(venv, known_helper) if known_helper is not None else None

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

    bin_dir = venv / "bin"
    if bin_dir.is_dir():
        for script in bin_dir.glob("*"):
            if script.is_symlink() or not script.is_file() or is_macho(script):
                continue
            text = script.read_text(errors="replace")
            if not text.startswith("#!"):
                continue
            for fragment in forbidden_launcher_fragments:
                if fragment in text:
                    errors.append(f"script launcher has build-host path fragment {fragment!r}: {rel(script)}")
                    break

    if run_smoke and python.exists() and not python.is_symlink():
        smoke = run_smoke_command(
            [str(python), "-c", "import sys; print(sys.executable)"],
            {"PATH": "/usr/bin:/bin", "HOME": "/tmp"},
            f"sanitized interpreter smoke failed: {rel(python)}",
        )
        if smoke is not None and smoke.returncode != 0:
            errors.append(f"sanitized interpreter smoke failed: {rel(python)}: {detail_from(smoke)}")
        if known_helper is not None and known_entry is not None:
            verify_known_helper_smoke(venv, python, known_entry, known_helper)


venv_roots = discover_venvs()
for venv in venv_roots:
    verify_venv(venv)


def executable_dir_for(macho: pathlib.Path) -> Optional[pathlib.Path]:
    for venv in venv_roots:
        try:
            macho.relative_to(venv)
        except ValueError:
            continue
        return venv / "bin"
    return None


machos = discover_machos()
for macho in machos:
    executable_dir = executable_dir_for(macho)
    for rpaths, deps in parse_macho_loads(macho, executable_dir):
        for dep in deps:
            verify_dependency(macho, executable_dir, rpaths, dep)

if errors:
    print("\n".join(errors))
    sys.exit(1)

for macho in machos:
    print(f"ok\t{rel(macho)}")
PY
