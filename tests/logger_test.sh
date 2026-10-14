#!/bin/bash
# Tests of util/logger.sh: level filtering, the default level, case-insensitive levels, multi-word messages.
# The logger needs bash 4 (associative arrays), on macOS use the bash of brew.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

(("$(bash -c 'echo "${BASH_VERSINFO[0]}"')" >= 4)) || skip "requires bash 4 in PATH"

# run_logger <LOGGER_LEVEL, empty for unset> <logger arguments...>: the output of one logger call
run_logger() {
  local level="$1"
  shift
  LEVEL="$level" bash -c '
    [[ -n "$LEVEL" ]] && export LOGGER_LEVEL="$LEVEL" || unset LOGGER_LEVEL
    source util/logger.sh
    logger "$@"
  ' _ "$@"
}

section "default level"
check_contains "INFO is shown" "[INFO] visible" "$(run_logger "" INFO visible)"
check_contains "no level means INFO" "[INFO] plain message" "$(run_logger "" plain message)"
check "DEBUG is hidden" "" "$(run_logger "" DEBUG hidden)"
check_contains "ERROR is shown" "[ERROR] broken" "$(run_logger "" ERROR broken)"

section "levels"
check_contains "DEBUG level shows DEBUG" "[DEBUG] visible" "$(run_logger DEBUG DEBUG visible)"
check "WARN level hides INFO" "" "$(run_logger WARN INFO hidden)"
check_contains "WARN level shows WARN" "[WARN] visible" "$(run_logger WARN WARN visible)"
check "ERROR level hides WARN" "" "$(run_logger ERROR WARN hidden)"
check_contains "ERROR level shows ERROR" "[ERROR] visible" "$(run_logger ERROR ERROR visible)"

section "case"
check_contains "lower case message level" "[WARN] visible" "$(run_logger INFO warn visible)"
check_contains "lower case LOGGER_LEVEL" "[ERROR] visible" "$(run_logger error ERROR visible)"
check "lower case LOGGER_LEVEL filters" "" "$(run_logger error warn hidden)"

section "format"
check_contains "message words are joined" "[INFO] one two three" "$(run_logger INFO INFO one two three)"
line="$(run_logger INFO INFO message)"
if [[ "$line" =~ ^\[[0-9]{2}/[0-9]{2}/[0-9]{4}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\]\ \[INFO\]\ message$ ]]; then
  pass "line is '[dd/mm/yyyy HH:MM:SS] [LEVEL] message'"
else
  fail "line is '[dd/mm/yyyy HH:MM:SS] [LEVEL] message'" "unexpected format" "$line"
fi
check_contains "escapes are interpreted" "$(printf 'a\nb')" "$(run_logger INFO INFO 'a\nb')"

finish
