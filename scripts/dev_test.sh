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
chmod +x "$MOCK_BIN/pgrep" "$MOCK_BIN/rm"

PATH="$MOCK_BIN:$PATH"
export HOME="$TEST_HOME" PATH RM_LOG

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

printf 'Development script clean safety tests passed.\n'
