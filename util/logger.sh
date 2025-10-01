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
# NOTE: if logger level is not set it will always be 'INFO'


declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
# Set default value
: "${LOGGER_LEVEL:='INFO'}"

logger() {
  LOGGER_LEVEL=$(echo "$LOGGER_LEVEL" | tr "[:lower:]" "[:upper:]")
  local log_priority="INFO"

  first_arg=$(echo "$1" | tr "[:lower:]" "[:upper:]")
  if [[ ${levels[$first_arg]} ]]; then
    local log_priority=$first_arg
    local log_message="${*:2}"
  else
    local log_message="${*:1}"
  fi

  # Check if level is enough
  [[ "${levels[$log_priority]}" < "${levels[$LOGGER_LEVEL]}" ]] && return 1

  # Log here
  echo -e "[$(date +'%d/%m/%Y %H:%M:%S')] [${log_priority}] ${log_message}"
}
