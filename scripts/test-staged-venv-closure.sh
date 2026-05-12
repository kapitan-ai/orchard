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
  *pyvenv.cfg*|*bin/tool*) echo text/plain ;;
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
    if PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" "$root" >"$out" 2>&1; then
        echo "expected verifier to fail with: $pattern" >&2
        cat "$out" >&2
        exit 1
    fi
    assert_grep "$pattern" "$out"
}

# materializer: same-path runtime lib skip, outbound python* symlink copy, and absolute Python shebang rewrite.
case_dir="$TMP_ROOT/materialize"
venv="$case_dir/native/foo/.venv"
runtime="$case_dir/runtime"
mkdir -p "$venv/bin" "$venv/lib" "$runtime/bin" "$runtime/lib"
cp /bin/ls "$runtime/bin/python3.13"
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
assert_verifier_fails_with 'outbound Mach-O dependency' "$tools" "$root" "$case_dir/out"

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
assert_verifier_fails_with 'outbound LC_RPATH' "$tools" "$root" "$case_dir/out"

printf 'ok	staged venv closure regressions
'
