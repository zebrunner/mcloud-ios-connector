#!/bin/bash

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
: ${LOGGER_LEVEL:="INFO"}

logger() {
    local log_priority=$1
    local log_message=$2

    # check if level exists
    [[ ${levels[$log_priority]} ]] || return 1

    # check if level is enough
    (( ${levels[$log_priority]} < ${levels[$LOGGER_LEVEL]} )) && return 2

    # log here
    echo -e "[$(date +'%d/%m/%Y %H:%M:%S')] [${log_priority}] : ${log_message}"
}