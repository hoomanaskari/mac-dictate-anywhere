#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Dictate Anywhere.xcodeproj"
SCHEME="Dictate Anywhere"
CONFIGURATION="Debug"
APP_NAME="Dictate Anywhere Dev.app"
DEFAULT_DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/DictateAnywhereDev"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DEFAULT_DERIVED_DATA_PATH}"
SIGNING_CONFIG_PATH="${SIGNING_CONFIG_PATH:-$ROOT_DIR/Config/Signing.local.xcconfig}"
ALLOW_PROVISIONING_UPDATES=0
RESULT_BUNDLE_PATH="$DERIVED_DATA_PATH/Logs/Test/DictateAnywhere.xcresult"
DEV_EXECUTABLE_NAME="Dictate Anywhere Dev"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  build [OPTIONS]
          Build the Debug app with automatic signing
  launch  Build and launch the canonical Debug app
  test [OPTIONS]
          Build and run the project tests
  check   Validate the Xcode project and Debug scheme
  clean   Stop the app and remove project DerivedData
  stop    Stop the running canonical app
  signing [TEAM_ID]
           Create the local Debug signing configuration with a Team ID
  help    Show this help

DerivedData: $DERIVED_DATA_PATH
Override with DERIVED_DATA_PATH, using a stable non-temporary path.

Build and test options:
  --configuration Debug|Release
          Select the build configuration (default: Debug)
  --release
           Alias for --configuration Release
  --allow-provisioning-updates
           Opt in to Xcode provisioning updates for build/test

Release builds use the production signing identity and team. They do not package or notarize the app.
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

parse_configuration_options() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --configuration)
        [[ "$#" -ge 2 ]] || fail "Missing value for --configuration (expected Debug or Release)"
        CONFIGURATION="$2"
        shift 2
        ;;
      --release)
        CONFIGURATION="Release"
        shift
        ;;
      --allow-provisioning-updates)
        ALLOW_PROVISIONING_UPDATES=1
        shift
        ;;
      --*)
        fail "Unknown option for build/test: $1"
        ;;
      *)
        fail "Unexpected argument for build/test: $1"
        ;;
    esac
  done

  case "$CONFIGURATION" in
    Debug|Release) ;;
    *) fail "Unknown configuration: $CONFIGURATION (expected Debug or Release)" ;;
  esac
}

validate_derived_data_path() {
  case "$DERIVED_DATA_PATH" in
    ""|/*/../*|/*/..|/tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
      fail "DERIVED_DATA_PATH must be an absolute, stable, non-temporary path"
      ;;
    /*) ;;
    *) fail "DERIVED_DATA_PATH must be an absolute, stable, non-temporary path" ;;
  esac
}

validate_clean_path() {
  [[ "$DERIVED_DATA_PATH" == "$DEFAULT_DERIVED_DATA_PATH" ]] || \
    fail "clean only supports the script-owned default DerivedData path: $DEFAULT_DERIVED_DATA_PATH"
  [[ "$DEFAULT_DERIVED_DATA_PATH" == "$HOME/Library/Developer/Xcode/DerivedData/DictateAnywhereDev" ]] || \
    fail "The default DerivedData path is not in its expected location"
  [[ "$DEFAULT_DERIVED_DATA_PATH" != "/" && "$DEFAULT_DERIVED_DATA_PATH" != "$HOME" ]] || \
    fail "Refusing to recursively remove a broad path"

  local canonical_home canonical_parent expected_parent
  canonical_home="$(cd -P -- "$HOME" 2>/dev/null && pwd -P)" || \
    fail "Could not resolve the home directory for clean"
  expected_parent="$canonical_home/Library/Developer/Xcode/DerivedData"
  canonical_parent="$(cd -P -- "$expected_parent" 2>/dev/null && pwd -P)" || \
    fail "The default DerivedData parent must exist before clean"
  [[ "$canonical_parent" == "$expected_parent" ]] || \
    fail "Refusing to clean through a redirected DerivedData parent"
}

configure_xcodebuild_args() {
  xcodebuild_args=(
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
  )

  if [[ "$CONFIGURATION" == "Debug" && -f "$SIGNING_CONFIG_PATH" ]]; then
    xcodebuild_args+=( -xcconfig "$SIGNING_CONFIG_PATH" )
  fi

  if [[ "$ALLOW_PROVISIONING_UPDATES" == 1 ]]; then
    xcodebuild_args+=( -allowProvisioningUpdates )
  fi
}

build() {
  printf 'Building %s (%s)\n' "$SCHEME" "$CONFIGURATION"
  xcodebuild "${xcodebuild_args[@]}" build
}

run_tests() {
  [[ "$CONFIGURATION" == "Debug" ]] || fail "Tests require the Debug configuration because Release is not testable"
  printf 'Testing %s (%s)\n' "$SCHEME" "$CONFIGURATION"
  rm -rf "$RESULT_BUNDLE_PATH"
  set +e
  xcodebuild "${xcodebuild_args[@]}" -resultBundlePath "$RESULT_BUNDLE_PATH" test
  local test_status=$?
  set -e
  local report_status=0
  if report_test_results; then
    :
  else
    report_status=$?
    printf 'Warning: test result reporting failed (status %s); preserving xcodebuild test status %s.\n' \
      "$report_status" "$test_status" >&2
  fi
  return "$test_status"
}

report_test_results() {
  local summary
  local total passed skipped failed
  [[ -d "$RESULT_BUNDLE_PATH" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    printf 'Warning: jq is unavailable; skipping custom test result summary.\n' >&2
    return 0
  fi
  if ! summary="$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE_PATH" --format json)"; then
    printf 'Warning: xcresulttool test-results summary is unavailable; skipping custom test result summary.\n' >&2
    return 0
  fi
  if ! total="$(jq -r '(.passedTests // 0) + (.skippedTests // 0) + (.failedTests // 0)' <<<"$summary")" || \
     ! passed="$(jq -r '.passedTests // 0' <<<"$summary")" || \
     ! skipped="$(jq -r '.skippedTests // 0' <<<"$summary")" || \
     ! failed="$(jq -r '.failedTests // 0' <<<"$summary")"; then
    printf 'Warning: could not parse test results from %s.\n' "$RESULT_BUNDLE_PATH" >&2
    return 1
  fi
  printf 'Tests: total=%s passed=%s skipped=%s failed=%s\n' \
    "$total" "$passed" "$skipped" "$failed"
}

check() {
  printf 'Checking %s (%s)\n' "$SCHEME" "$CONFIGURATION"
  xcodebuild "${xcodebuild_args[@]}" -showBuildSettings >/dev/null
  printf 'Project and scheme are valid.\n'
}

launch() {
  build
  local executable_path="$APP_PATH/Contents/MacOS/$DEV_EXECUTABLE_NAME"
  [[ -x "$executable_path" ]] || fail "Built executable not found at: $executable_path"
  stop
  printf 'Launching %s\n' "$APP_PATH"
  open -n "$APP_PATH"
}

process_owns_executable() {
  local pid="$1"
  local executable_path="$2"
  local text_path
  text_path="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
    | awk 'substr($0, 1, 1) == "n" { print substr($0, 2); exit }')"
  [[ "$text_path" == "$executable_path" ]]
}

development_pids() {
  local executable_path="$APP_PATH/Contents/MacOS/$DEV_EXECUTABLE_NAME"
  local pid
  while read -r pid; do
    if process_owns_executable "$pid" "$executable_path"; then
      printf '%s\n' "$pid"
    fi
  done < <(pgrep -x "$DEV_EXECUTABLE_NAME" || true)
}

process_start_time() {
  ps -p "$1" -o lstart= | awk '{$1=$1; print}'
}

process_is_owned() {
  local pid="$1"
  local expected_start_time="$2"
  local executable_path="$APP_PATH/Contents/MacOS/$DEV_EXECUTABLE_NAME"
  [[ "$(process_start_time "$pid")" == "$expected_start_time" ]] && \
    process_owns_executable "$pid" "$executable_path"
}

stop() {
  local pids pid start_time
  local -a owned_pids=()
  local -a start_times=()
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    owned_pids+=("$pid")
    start_times+=("$(process_start_time "$pid")")
  done < <(development_pids)

  pids="${owned_pids[*]:-}"
  if [[ -z "$pids" ]]; then
    printf '%s is not running\n' "$APP_NAME"
    return 0
  fi

  for pid in "${owned_pids[@]}"; do
    kill -TERM "$pid"
  done
  for _ in {1..20}; do
    [[ -z "$(development_pids)" ]] && { printf 'Stopped %s\n' "$APP_NAME"; return 0; }
    sleep 0.25
  done

  for ((i = 0; i < ${#owned_pids[@]}; i++)); do
    if process_is_owned "${owned_pids[$i]}" "${start_times[$i]}"; then
      kill -KILL "${owned_pids[$i]}" 2>/dev/null || true
    fi
  done
  [[ -z "$(development_pids)" ]] || fail "Could not stop the owned development process"
  printf 'Stopped %s\n' "$APP_NAME"
}

validate_lifecycle_contract() {
  [[ "$APP_NAME" == "Dictate Anywhere Dev.app" ]] || fail "Unexpected development app bundle name"
  [[ "$DEV_EXECUTABLE_NAME" == "Dictate Anywhere Dev" ]] || fail "Unexpected development executable name"
  command -v pgrep >/dev/null || fail "Missing required command: pgrep"
  command -v lsof >/dev/null || fail "Missing required command: lsof"
  printf 'Development lifecycle contract is valid.\n'
}

signing() {
  local signing_config="$SIGNING_CONFIG_PATH"
  local requested_team_id="${1:-}"
  local team_id
  local identity_output
  local team_ids
  local team_id_count

  [[ "$#" -le 1 ]] || fail "Usage: $(basename "$0") signing [TEAM_ID]"

  [[ ! -e "$signing_config" ]] || fail "Signing configuration already exists: $signing_config"

  if [[ -n "$requested_team_id" ]]; then
    [[ "$requested_team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "TEAM_ID must be a 10-character uppercase alphanumeric Team ID"
    team_id="$requested_team_id"
  else
    require_command security
    identity_output="$({ security find-identity -v -p codesigning 2>/dev/null || true; })"
    team_ids="$(printf '%s\n' "$identity_output" \
      | awk -F'[()]' '/"(Mac|Apple) Development:/ {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$/) print $i
          }
        }' \
      | sort -u)"
    team_id_count="$(printf '%s\n' "$team_ids" | awk 'NF { count++ } END { print count + 0 }')"
    case "$team_id_count" in
      0)
        fail "No Apple Development or Mac Development identity with a Team ID is installed. Add a matching development certificate and private key to the current Xcode account/keychain, then retry. The script cannot create certificates."
        ;;
      1)
        team_id="$team_ids"
        ;;
      *)
        fail "Multiple Team IDs are present in Apple Development or Mac Development identities: $(printf '%s' "$team_ids" | tr '\n' ' '). Pass one explicitly: $(basename "$0") signing TEAM_ID"
        ;;
    esac
  fi

  mkdir -p "$(dirname "$signing_config")"
  if ! (set -C; printf 'DEVELOPMENT_TEAM = %s\n' "$team_id" > "$signing_config"); then
    fail "Could not create signing configuration: $signing_config"
  fi

  case "$signing_config" in
    "$ROOT_DIR"/*)
      if command -v git >/dev/null 2>&1 && ! git -C "$ROOT_DIR" check-ignore -q -- "$signing_config"; then
        printf 'Warning: Git does not ignore %s; remove it from tracking before committing.\n' "$signing_config" >&2
      fi
      ;;
    *)
      printf 'Warning: %s is outside the repository and is not covered by its .gitignore.\n' "$signing_config" >&2
      ;;
  esac
  printf 'Created local Debug signing configuration: %s\n' "$signing_config"
}

command="${1:-help}"
if [[ "$command" == "help" || "$command" == "-h" || "$command" == "--help" ]]; then
  [[ "$#" -eq 0 || "$#" -eq 1 ]] || fail "Usage: $(basename "$0") help"
  usage
  exit 0
fi

if [[ "$command" == "signing" ]]; then
  signing "${@:2}"
  exit 0
fi

case "$command" in
  build|test)
    parse_configuration_options "${@:2}"
    ;;
  launch|check|clean|stop)
    [[ "$#" -eq 1 ]] || fail "Usage: $(basename "$0") $command"
    ;;
  *)
    CONFIGURATION="Debug"
    ;;
esac

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
configure_xcodebuild_args

validate_derived_data_path

case "$command" in
  build) require_command xcodebuild; build ;;
  launch) launch ;;
  test) require_command xcodebuild; run_tests ;;
  check) require_command xcodebuild; check; validate_lifecycle_contract ;;
  clean) validate_clean_path; stop; rm -rf -- "$HOME/Library/Developer/Xcode/DerivedData/DictateAnywhereDev"; printf 'Removed DerivedData: %s\n' "$DEFAULT_DERIVED_DATA_PATH" ;;
  stop) stop ;;
  *) usage >&2; fail "Unknown command: $command" ;;
esac
