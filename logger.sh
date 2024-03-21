#!/bin/bash

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
: "${LOGGER_LEVEL:="INFO"}"

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
  ((${levels[$log_priority]} < ${levels[$LOGGER_LEVEL]})) && return 1

  # Log here
  echo -e "[$(date +'%d/%m/%Y %H:%M:%S')] [${log_priority}] ${log_message}"
}
