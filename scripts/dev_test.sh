#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/dev.sh"
TEST_ROOT="$(mktemp -d "$SCRIPT_DIR/.dev-test.XXXXXX")"
MOCK_BIN="$TEST_ROOT/bin"
RM_LOG="$TEST_ROOT/rm.log"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME/Library/Developer/Xcode/DerivedData" "$MOCK_BIN"
trap '/bin/rm -rf -- "$TEST_ROOT"' EXIT

cat > "$MOCK_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$MOCK_BIN/rm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RM_LOG"
EOF
cat > "$MOCK_BIN/xcodebuild" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$XCODEBUILD_ARGS_LOG"
EOF
cat > "$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then
  printf '%s\n' "$MOCK_HOST_ARCH"
else
  /usr/bin/uname "$@"
fi
EOF
cat > "$MOCK_BIN/open" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN/pgrep" "$MOCK_BIN/rm" "$MOCK_BIN/xcodebuild" "$MOCK_BIN/uname" "$MOCK_BIN/open"

PATH="$MOCK_BIN:$PATH"
export HOME="$TEST_HOME" PATH RM_LOG XCODEBUILD_ARGS_LOG="$TEST_ROOT/xcodebuild-args.log"

unset DERIVED_DATA_PATH
default_path="$HOME/Library/Developer/Xcode/DerivedData/DictateAnywhereDev"

if ! "$SCRIPT" clean >/dev/null; then
  printf 'FAIL: the default project directory was rejected\n' >&2
  exit 1
fi
if [[ "$(<"$RM_LOG")" != "-rf -- $default_path" ]]; then
  printf 'FAIL: clean did not target the exact default project directory\n' >&2
  exit 1
fi

/bin/rm -rf -- "$HOME/Library/Developer/Xcode/DerivedData"
redirected_target="$TEST_ROOT/redirect-target/DictateAnywhereDev"
mkdir -p "$redirected_target"
printf 'must survive\n' > "$redirected_target/marker"
mkdir -p "$HOME/Library/Developer/Xcode"
ln -s "$TEST_ROOT/redirect-target" "$HOME/Library/Developer/Xcode/DerivedData"
if "$SCRIPT" clean >/dev/null 2>&1; then
  printf 'FAIL: clean followed a symlinked DerivedData parent\n' >&2
  exit 1
fi
if [[ ! -e "$redirected_target/marker" ]]; then
  printf 'FAIL: the redirected clean target was deleted\n' >&2
  exit 1
fi
/bin/rm "$HOME/Library/Developer/Xcode/DerivedData"
mkdir -p "$HOME/Library/Developer/Xcode/DerivedData"

dangerous_paths=(
  "/"
  "$HOME"
  "$SCRIPT_DIR/.."
  "$HOME/Library/Developer/Xcode/DerivedData"
  "$HOME/custom-derived-data"
)
for dangerous_path in "${dangerous_paths[@]}"; do
  if DERIVED_DATA_PATH="$dangerous_path" "$SCRIPT" clean >/dev/null 2>&1; then
    printf 'FAIL: dangerous clean path was accepted: %s\n' "$dangerous_path" >&2
    exit 1
  fi
done

if [[ "$(wc -l < "$RM_LOG" | tr -d ' ')" != "1" ]]; then
  printf 'FAIL: a rejected clean path reached rm\n' >&2
  exit 1
fi

executable="$default_path/Build/Products/Debug/Dictate Anywhere Dev.app/Contents/MacOS/Dictate Anywhere Dev"
mkdir -p "$(dirname "$executable")"
touch "$executable"
chmod +x "$executable"

for host_arch in arm64 x86_64; do
  for command in build launch test benchmark check; do
    MOCK_HOST_ARCH="$host_arch" "$SCRIPT" "$command" >/dev/null
    if ! /usr/bin/grep -Fxq 'platform=macOS' "$XCODEBUILD_ARGS_LOG" || \
       /usr/bin/grep -Eq 'arch=|^ARCHS=' "$XCODEBUILD_ARGS_LOG"; then
      printf 'FAIL: %s did not select a native macOS destination on %s\n' "$command" "$host_arch" >&2
      exit 1
    fi
  done
done

printf 'Development script architecture selection tests passed.\n'
printf 'Development script clean safety tests passed.\n'
