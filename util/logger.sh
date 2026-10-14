#!/bin/bash

#### Help:
# To use logger you need to call this file from your code e.g.
# '. /some/path/logger.sh'
#
# You can use following env vars to control logger:
# LOGGER_LEVEL=[DEBUG/INFO/WARN/ERROR]       (default: INFO)    - Lower level of logs to show
#
# Examples:
# > logger info info_message
#   [26/03/2024 10:20:22] [INFO] info_message
# > logger Error error_message
#   [26/03/2024 10:22:53] [ERROR] error_message
# > logger no_logger_level
#   [26/03/2024 10:24:38] [INFO] no_logger_level
# NOTE: if logger level is not set or unknown it will always be 'INFO'

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
# Set default value
: "${LOGGER_LEVEL:=INFO}"

logger() {
  local level="${LOGGER_LEVEL^^}"
  # An unknown level is the default one
  [[ -n "${levels[$level]}" ]] || level="INFO"
  local log_priority="INFO"
  local log_message="${*:1}"

  local first_arg="${1^^}"
  if [[ -n "$first_arg" && -n "${levels[$first_arg]}" ]]; then
    log_priority="$first_arg"
    log_message="${*:2}"
  fi

  # Check if level is enough
  [[ "${levels[$log_priority]}" -lt "${levels[$level]}" ]] && return 1

  # Log here
  echo -e "[$(date +'%d/%m/%Y %H:%M:%S')] [${log_priority}] ${log_message}"
}
