#!/bin/bash
# Focused regression tests for staged Python venv materialization/closure checks.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_fake_tools() {
    local tools="$1"
    local otool_body="$2"
    mkdir -p "$tools"
    cat > "$tools/file" <<'SH'
#!/bin/sh
case "$*" in
  *pyvenv.cfg*|*bin/tool*|*bin/orchard-tokenizer|*.py|*.pth) echo text/plain ;;
  *) echo application/x-mach-binary ;;
esac
SH
    printf '%s
' "$otool_body" > "$tools/otool"
    chmod +x "$tools/file" "$tools/otool"
}

make_venv_fixture() {
    local root="$1"
    local venv="$root/Library/Application Support/Orchard/native/foo/.venv"
    mkdir -p "$venv/bin" "$venv/lib"
    cat > "$venv/bin/python" <<'SH'
#!/bin/sh
exit 0
SH
    chmod +x "$venv/bin/python"
    printf 'include-system-site-packages = false
version = 3.13.5
' > "$venv/pyvenv.cfg"
    echo "$venv"
}

assert_no_grep() {
    local pattern="$1"
    local file="$2"
    if grep -F "$pattern" "$file"; then
        echo "unexpected match for $pattern" >&2
        exit 1
    fi
}

assert_grep() {
    local pattern="$1"
    local file="$2"
    grep -F "$pattern" "$file" >/dev/null
}

assert_verifier_fails_with() {
    local pattern="$1"
    local tools="$2"
    local root="$3"
    local out="$4"
    shift 4
    if PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" "$@" "$root" >"$out" 2>&1; then
        echo "expected verifier to fail with: $pattern" >&2
        cat "$out" >&2
        exit 1
    fi
    assert_grep "$pattern" "$out"
}

assert_verifier_succeeds() {
    local tools="$1"
    local root="$2"
    local out="$3"
    shift 3
    PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" "$@" "$root" >"$out" 2>&1
}

site_packages_dir() {
    local venv="$1"
    find "$venv/lib" -type d -path '*/site-packages' -print -quit
}

make_known_helper_venv_fixture() {
    local root="$1"
    local package_state="${2:-present}"
    local entry_state="${3:-ok}"
    local helper="${4:-orchard_tokenizer}"
    local entry_name="orchard-tokenizer"
    if [[ "$helper" == "orchard_worker_mlx" ]]; then
        entry_name="orchard-worker-mlx"
    fi
    local venv="$root/Library/Application Support/Orchard/native/$helper/.venv"
    python3 -m venv --copies "$venv"
    if [[ -L "$venv/bin/python" ]]; then
        echo "fixture setup failed: expected non-symlink venv/bin/python" >&2
        exit 1
    fi
    grep -Ev '^(home|executable|command) = |/Users/|/opt/homebrew/|/tmp/' "$venv/pyvenv.cfg" > "$venv/pyvenv.cfg.tmp"
    mv "$venv/pyvenv.cfg.tmp" "$venv/pyvenv.cfg"

    local site_packages
    site_packages="$(site_packages_dir "$venv")"
    find "$site_packages" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    if [[ "$package_state" == "present" ]]; then
        mkdir -p "$site_packages/$helper"
        printf '' > "$site_packages/$helper/__init__.py"
        cat > "$site_packages/$helper/cli.py" <<'PY'
def main():
    return 0
PY
    fi

    case "$entry_state" in
      ok)
        cat > "$venv/bin/$entry_name" <<'SH'
#!/bin/sh
case "${1:-}" in
  --help) exit 0 ;;
esac
exit 0
SH
        chmod +x "$venv/bin/$entry_name"
        ;;
      fail)
        cat > "$venv/bin/$entry_name" <<'SH'
#!/bin/sh
exit 7
SH
        chmod +x "$venv/bin/$entry_name"
        ;;
      sleep)
        cat > "$venv/bin/$entry_name" <<'SH'
#!/bin/sh
sleep 30
SH
        chmod +x "$venv/bin/$entry_name"
        ;;
      nonexec)
        printf '#!/bin/sh\nexit 0\n' > "$venv/bin/$entry_name"
        chmod 644 "$venv/bin/$entry_name"
        ;;
      missing)
        ;;
      *)
        echo "unknown entry fixture state: $entry_state" >&2
        exit 1
        ;;
    esac

    echo "$venv"
}

# materializer: same-path runtime lib skip, outbound python* symlink copy, and absolute Python shebang rewrite.
case_dir="$TMP_ROOT/materialize"
venv="$case_dir/native/foo/.venv"
runtime="$case_dir/runtime"
mkdir -p "$venv/bin" "$venv/lib" "$runtime/bin" "$runtime/lib"
cp /bin/ls "$runtime/bin/python3.13"
if command -v xattr >/dev/null 2>&1; then
    xattr -w com.apple.quarantine 'test-quarantine' "$runtime/bin/python3.13" 2>/dev/null || true
fi
ln -s "$runtime/bin/python3.13" "$venv/bin/python"
ln -s "$runtime/bin/python3.13" "$venv/bin/python3"
cat > "$venv/bin/tool" <<'SH'
#!/Users/buildhost/project/.venv/bin/python
print('ok')
SH
chmod +x "$venv/bin/tool"
"$REPO_ROOT/scripts/materialize-staged-venv-interpreters.sh" "$case_dir/native" >/dev/null
test ! -L "$venv/bin/python"
test ! -L "$venv/bin/python3"
if command -v xattr >/dev/null 2>&1; then
    ! xattr "$venv/bin/python3" 2>/dev/null | grep -F 'com.apple.quarantine'
fi
head -3 "$venv/bin/tool" | grep -F '#!/bin/sh' >/dev/null
assert_no_grep '/Users/buildhost' "$venv/bin/tool"

# verifier: LC_ID_DYLIB/self install name is ignored as a non-dependency.
case_dir="$TMP_ROOT/lc-id"
tools="$case_dir/tools"
root="$case_dir/root"
make_venv_fixture "$root" >/dev/null
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
Load command 0
          cmd LC_ID_DYLIB
      cmdsize 104
         name /Users/buildhost/libself.dylib (offset 24)
OUT'
PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" "$root" >"$case_dir/out" 2>&1
assert_no_grep 'outbound Mach-O dependency' "$case_dir/out"

# verifier: install-prefix absolute dependency with spaces maps into staging.
case_dir="$TMP_ROOT/install-prefix"
tools="$case_dir/tools"
root="$case_dir/root"
venv="$(make_venv_fixture "$root")"
: > "$venv/lib/libfoo.dylib"
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /Library/Application Support/Orchard/native/foo/.venv/lib/libfoo.dylib (offset 24)
OUT'
PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" "$root" >"$case_dir/out" 2>&1
assert_no_grep 'outbound Mach-O dependency' "$case_dir/out"

# verifier: @loader_path and @executable_path rpaths may expand under staging.
case_dir="$TMP_ROOT/token-rpath"
tools="$case_dir/tools"
root="$case_dir/root"
venv="$(make_venv_fixture "$root")"
: > "$venv/bin/libfoo.dylib"
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
Load command 0
          cmd LC_RPATH
      cmdsize 48
         path @executable_path (offset 12)
Load command 1
          cmd LC_LOAD_DYLIB
      cmdsize 56
         name @rpath/libfoo.dylib (offset 24)
OUT'
PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" "$root" >"$case_dir/out" 2>&1
assert_no_grep 'outbound LC_RPATH' "$case_dir/out"
assert_no_grep 'unresolved @rpath dependency' "$case_dir/out"

# verifier: host-bound Python shebangs are rejected.
case_dir="$TMP_ROOT/shebang"
tools="$case_dir/tools"
root="$case_dir/root"
venv="$(make_venv_fixture "$root")"
cat > "$venv/bin/tool" <<'SH'
#!/Users/buildhost/project/.venv/bin/python
print('bad')
SH
chmod +x "$venv/bin/tool"
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
OUT'
assert_verifier_fails_with 'script shebang has build-host path fragment' "$tools" "$root" "$case_dir/out"

# verifier: temp build-root absolute dependency is rejected.
case_dir="$TMP_ROOT/temp-root"
tools="$case_dir/tools"
root="$case_dir/root"
make_venv_fixture "$root" >/dev/null
make_fake_tools "$tools" "#!/bin/sh
cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name $root/Library/Application Support/Orchard/native/foo/.venv/lib/libfoo.dylib (offset 24)
OUT"
assert_verifier_fails_with "forbidden Mach-O dependency" "$tools" "$root" "$case_dir/out"

# verifier: unsafe absolute LC_RPATH is rejected.
case_dir="$TMP_ROOT/rpath"
tools="$case_dir/tools"
root="$case_dir/root"
make_venv_fixture "$root" >/dev/null
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
Load command 0
          cmd LC_RPATH
      cmdsize 48
         path /Users/buildhost/lib (offset 12)
Load command 1
          cmd LC_LOAD_DYLIB
      cmdsize 56
         name @rpath/libfoo.dylib (offset 24)
OUT'
assert_verifier_fails_with 'forbidden LC_RPATH' "$tools" "$root" "$case_dir/out"

# verifier: known native helper package imports must work under sanitized env.
case_dir="$TMP_ROOT/known-helper-missing-package"
tools="$case_dir/tools"
root="$case_dir/root"
make_known_helper_venv_fixture "$root" missing ok >/dev/null
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
OUT'
assert_verifier_fails_with 'orchard_tokenizer package not importable' "$tools" "$root" "$case_dir/out"
assert_verifier_fails_with 'orchard_tokenizer package __init__.py missing from staged venv site-packages' "$tools" "$root" "$case_dir/no-smoke.out" --no-smoke

# verifier: Orchard editable .pth hooks are never allowed in staged helper venvs.
case_dir="$TMP_ROOT/known-helper-editable-pth"
tools="$case_dir/tools"
root="$case_dir/root"
venv="$(make_known_helper_venv_fixture "$root" present ok)"
printf '/Users/buildhost/orchard/native/orchard_tokenizer/src
' > "$(site_packages_dir "$venv")/_editable_impl_orchard_tokenizer.pth"
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
OUT'
assert_verifier_fails_with 'Orchard editable .pth present in staged venv' "$tools" "$root" "$case_dir/out"
assert_verifier_fails_with 'Orchard editable .pth present in staged venv' "$tools" "$root" "$case_dir/no-smoke.out" --no-smoke

# verifier: plain build-host source-path .pth hooks are rejected even without editable naming.
case_dir="$TMP_ROOT/known-helper-source-path-pth"
tools="$case_dir/tools"
root="$case_dir/root"
venv="$(make_known_helper_venv_fixture "$root" present ok)"
printf '/Users/buildhost/orchard/native/orchard_tokenizer/src
' > "$(site_packages_dir "$venv")/orchard_tokenizer_source.pth"
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
OUT'
assert_verifier_fails_with 'Orchard editable .pth present in staged venv' "$tools" "$root" "$case_dir/out"
assert_verifier_fails_with 'Orchard editable .pth present in staged venv' "$tools" "$root" "$case_dir/no-smoke.out" --no-smoke

# verifier: worker helper package import and entrypoint smokes are covered.
case_dir="$TMP_ROOT/known-worker-helper-ok"
tools="$case_dir/tools"
root="$case_dir/root"
make_known_helper_venv_fixture "$root" present ok orchard_worker_mlx >/dev/null
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
OUT'
assert_verifier_succeeds "$tools" "$root" "$case_dir/out"

# verifier: known helper console entrypoints must smoke under sanitized env.
case_dir="$TMP_ROOT/known-helper-entrypoint-smoke"
tools="$case_dir/tools"
root="$case_dir/root"
make_known_helper_venv_fixture "$root" present fail >/dev/null
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
OUT'
assert_verifier_fails_with 'orchard-tokenizer entrypoint smoke failed' "$tools" "$root" "$case_dir/out"
assert_verifier_succeeds "$tools" "$root" "$case_dir/no-smoke.out" --no-smoke
assert_no_grep 'orchard-tokenizer entrypoint smoke failed' "$case_dir/no-smoke.out"

# verifier: known helper console entrypoint smokes time out quickly.
case_dir="$TMP_ROOT/known-helper-entrypoint-timeout"
tools="$case_dir/tools"
root="$case_dir/root"
make_known_helper_venv_fixture "$root" present sleep >/dev/null
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
OUT'
assert_verifier_fails_with 'orchard-tokenizer entrypoint smoke failed' "$tools" "$root" "$case_dir/out"
assert_verifier_succeeds "$tools" "$root" "$case_dir/no-smoke.out" --no-smoke
assert_no_grep 'timed out' "$case_dir/no-smoke.out"

# verifier: known helper console entrypoints must exist and be executable.
case_dir="$TMP_ROOT/known-helper-entrypoint-missing"
tools="$case_dir/tools"
root="$case_dir/root"
make_known_helper_venv_fixture "$root" present missing >/dev/null
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
OUT'
assert_verifier_fails_with 'expected entrypoint missing or not executable' "$tools" "$root" "$case_dir/out"
assert_verifier_fails_with 'expected entrypoint missing or not executable' "$tools" "$root" "$case_dir/no-smoke.out" --no-smoke

case_dir="$TMP_ROOT/known-helper-entrypoint-nonexec"
tools="$case_dir/tools"
root="$case_dir/root"
make_known_helper_venv_fixture "$root" present nonexec >/dev/null
make_fake_tools "$tools" '#!/bin/sh
cat <<'"'"'OUT'"'"'
OUT'
assert_verifier_fails_with 'expected entrypoint missing or not executable' "$tools" "$root" "$case_dir/out"
assert_verifier_fails_with 'expected entrypoint missing or not executable' "$tools" "$root" "$case_dir/no-smoke.out" --no-smoke

printf 'ok	staged venv closure regressions
'
