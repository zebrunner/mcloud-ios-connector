#!/bin/bash
# Tests of entrypoint.sh with stubs of ios, nc, socat, curl and the other tools: no device, no docker.
# The image paths (/opt/zebrunner) are replaced with the repository, the waits are stubs.
# The entrypoint needs bash 4, on macOS use the bash of brew.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

(("$(bash -c 'echo "${BASH_VERSINFO[0]}"')" >= 4)) || skip "requires bash 4 in PATH"

sed -e "s#/opt/zebrunner/#${REPO}/#g" -e "s#/tmp/log/#${WORK}/log/#g" entrypoint.sh > "${WORK}/entrypoint.sh"
mkdir -p "${WORK}/log"

# the stubs read their behavior from the FAKE_* variables of the scenario
export FAKE_WORK="$WORK"
record_stub socat
record_stub usbmuxd
record_stub go-ncm
stub jq 'cat'
stub tail 'exit 0'
# the entrypoint holder sleeps 33 seconds between the WDA checks: before the first one WDA stops answering,
# with FAKE_FLAP=1 it answers again before the second one;
# a failing background process (FAKE_PGREP is not ok) is awaited, its failure is the file with the exit code
stub sleep 'if [[ "$1" == 33 ]]; then
  if [[ "$FAKE_PGREP" != ok ]]; then
    for _ in $(seq 300); do
      [[ -s "$FAKE_WORK/log/background.exit" ]] && break
      /bin/sleep 0.1
    done
  fi
  n=$(cat "$FAKE_WORK/sleep33.n" 2> /dev/null || echo 0)
  echo $((n + 1)) > "$FAKE_WORK/sleep33.n"
  if [[ "$FAKE_FLAP" == 1 && "$n" == 1 ]]; then touch "$FAKE_WORK/wda_ok"; else rm -f "$FAKE_WORK/wda_ok"; fi
fi
exit 0'
# nc: the first call checks that the usbmuxd port is free, the next ones that it is forwarded
stub nc 'n=$(cat "$FAKE_WORK/nc.n" 2> /dev/null || echo 0); echo $((n + 1)) > "$FAKE_WORK/nc.n"
[[ "$FAKE_PORT_BUSY" == 1 ]] && exit 0
[[ "$FAKE_NC" == nofwd ]] && exit 1
[[ "$n" -gt 0 ]]'
# curl: the metrics of go-ncm (FAKE_NCM), the tunnels of go-ios (FAKE_TUNNEL) and the status of WDA (the wda_ok file),
# FAKE_WDA_AFTER is the number of the status requests WDA does not answer yet
stub curl 'case "$*" in
  *3030/metrics*)
    if [[ "$*" == *-Is* ]]; then
      [[ "$FAKE_NCM" == down ]] || echo "HTTP/1.1 200 OK"
    else
      [[ "$FAKE_NCM" == zero ]] && echo "device_count 0" || echo "device_count 1"
    fi ;;
  *60105/tunnels*)
    if [[ "$*" == *-w* ]]; then
      [[ "$FAKE_TUNNEL" == down ]] && echo 000 || echo 200
    else
      [[ "$FAKE_TUNNEL" == nodevice ]] && echo "[]" || echo "[{\"udid\":\"${DEVICE_UDID}\"}]"
    fi ;;
  *-Is*)
    [[ -e "$FAKE_WORK/wda_ok" ]] || exit 0
    n=$(cat "$FAKE_WORK/curl.n" 2> /dev/null || echo 0)
    echo $((n + 1)) > "$FAKE_WORK/curl.n"
    [[ "$n" -ge "$FAKE_WDA_AFTER" ]] && echo "HTTP/1.1 200 OK" ;;
esac
exit 0'
# pgrep: a process is missing on the first check of its pattern and running on the next ones,
# FAKE_PGREP=never: always missing, FAKE_PGREP=runwda: ios runwda is always missing
stub pgrep '[[ "$FAKE_PGREP" == never ]] && exit 1
[[ "$FAKE_PGREP" == runwda && "$*" == *"ios runwda"* ]] && exit 1
f="$FAKE_WORK/pgrep-$(echo "$*" | tr -c "a-z0-9" _)"
[[ -e "$f" ]] && exit 0
touch "$f"
exit 1'
# ios: runwda starts WDA (the wda_ok file)
stub ios 'echo "ios|$*" >> "$FAKE_WORK/calls.log"
case "$1" in
  info)
    n=$(cat "$FAKE_WORK/info.n" 2> /dev/null || echo 0)
    echo $((n + 1)) > "$FAKE_WORK/info.n"
    [[ "$FAKE_DEVICE" == flaky && "$n" -lt "$FAKE_INFO_FAILS" ]] && { echo "device not found"; exit 1; }
    [[ "$FAKE_DEVICE" == absent ]] && { echo "device not found"; exit 1; }
    [[ "$FAKE_DEVICE" == missing ]] && { echo "failed getting info"; exit 1; }
    [[ "$FAKE_DEVICE" == timeout ]] && { echo "Timed out waiting for response for message:5 channel:0"; exit 1; }
    echo "{\"ProductVersion\":\"${FAKE_IOS_VERSION}\"}" ;;
  image) echo "${FAKE_IMAGE_RESULT}" ;;
  apps) [[ "$FAKE_WDA_INSTALLED" == 1 ]] && echo "${WDA_BUNDLEID}" ;;
  install) [[ "$FAKE_INSTALL" == fail ]] && echo "{\"err\":\"install failed\"}" ;;
  runwda) touch "$FAKE_WORK/wda_ok" ;;
esac
exit 0'

# scenario <name>: a fresh state, a healthy iOS 16 device on macOS (HOST_OS=DARWIN) with WDA installed by default
scenario() {
  rm -f "${WORK}"/*.n "${WORK}"/nc.n "${WORK}"/log/* "${WORK}/WebDriverAgent.ipa" "${WORK}"/pgrep-* "${WORK}/wda_ok"
  touch "${WORK}/wda_ok"
  reset_calls
  FAKE_PORT_BUSY=0
  FAKE_DEVICE=ok
  FAKE_IOS_VERSION=16.4.1
  FAKE_IMAGE_RESULT='success mounting image'
  FAKE_WDA_INSTALLED=1
  FAKE_INSTALL=ok
  FAKE_NCM=ok
  FAKE_TUNNEL=ok
  FAKE_NC=ok
  FAKE_PGREP=ok
  FAKE_FLAP=0
  FAKE_WDA_AFTER=0
  FAKE_INFO_FAILS=0
  export FAKE_NC FAKE_PGREP FAKE_FLAP FAKE_WDA_AFTER FAKE_INFO_FAILS
  export FAKE_PORT_BUSY FAKE_DEVICE FAKE_IOS_VERSION FAKE_IMAGE_RESULT FAKE_WDA_INSTALLED FAKE_INSTALL FAKE_NCM FAKE_TUNNEL
  export HOST_OS=DARWIN DEVICE_UDID=00008030-TEST POLLING_SEC=0 USBMUXD_PORT=2222 USBMUXD_SOCKET_ADDRESS=''
  export WDA_HOST=localhost WDA_PORT=8100 MJPEG_PORT=8101 WDA_WAIT_TIMEOUT=2
  export WDA_BUNDLEID=com.facebook.WebDriverAgentRunner.xctrunner WDA_LOG_FILE="${WORK}/wda.log"
  export WDA_FILE="${WORK}/WebDriverAgent.ipa" LOGGER_LEVEL=DEBUG
  unset DEBUG VERBOSE TEST_RUNNER_BUNDLE_ID XCTEST_CONFIG
}

# run_entrypoint: output of the entrypoint in $OUT, its exit status in $STATUS
run_entrypoint() {
  OUT="$(PATH="${WORK}/bin:${PATH}" bash "${WORK}/entrypoint.sh" 2>&1)"
  STATUS=$?
}

section "configuration"
scenario
DEVICE_UDID=''
run_entrypoint
check_contains "empty DEVICE_UDID is reported" "DEVICE_UDID is required" "$OUT"
check_contains "invalid configuration is reported" "Invalid configuration. Exiting!" "$OUT"
check "invalid configuration exits with 0" "0" "$STATUS"
check "nothing is started with invalid configuration" "" "$(calls ios)$(calls socat)$(calls usbmuxd)"

scenario
unset DEVICE_UDID
run_entrypoint
check_contains "unset DEVICE_UDID is reported" "DEVICE_UDID is required" "$OUT"

for var in POLLING_SEC USBMUXD_PORT WDA_PORT MJPEG_PORT WDA_WAIT_TIMEOUT; do
  for value in "" abc -1 1.5 "1 2"; do
    scenario
    export "${var}=${value}"
    run_entrypoint
    check_contains "${var}='${value}' is reported" "${var} must be a non-negative integer, but it is '${value}'." "$OUT"
    check "${var}='${value}' exits with 0" "0" "$STATUS"
  done
done

scenario
POLLING_SEC=abc
WDA_PORT=xyz
run_entrypoint
check_contains "every invalid variable is reported: first" "POLLING_SEC must be" "$OUT"
check_contains "every invalid variable is reported: second" "WDA_PORT must be" "$OUT"

scenario
unset HOST_OS
FAKE_WDA_INSTALLED=0
run_entrypoint
check_contains "HOST_OS is LINUX by default" "file is not exist or not a regular file" "$OUT"

scenario
HOST_OS=''
FAKE_WDA_INSTALLED=0
run_entrypoint
check_contains "empty HOST_OS is LINUX" "file is not exist or not a regular file" "$OUT"

for value in LINUX linux Linux DARWIN darwin MACOS macos; do
  scenario
  HOST_OS=$value
  FAKE_PORT_BUSY=1
  run_entrypoint
  check_not_contains "HOST_OS='${value}' is valid" "HOST_OS must be" "$OUT"
done

for value in windows LINUX2 "MAC OS" ubuntu; do
  scenario
  HOST_OS=$value
  run_entrypoint
  check_contains "HOST_OS='${value}' is reported" "HOST_OS must be LINUX, DARWIN or MACOS, but it is '${value}'." "$OUT"
  check "HOST_OS='${value}' exits with 0" "0" "$STATUS"
  check "nothing is started with HOST_OS='${value}'" "" "$(calls ios)$(calls socat)$(calls usbmuxd)"
done

section "DEBUG and VERBOSE"
scenario
DEVICE_UDID=''
DEBUG=true
DEBUG_TIMEOUT=0
export DEBUG DEBUG_TIMEOUT
run_entrypoint
check_contains "DEBUG banner" "DEBUG mode is on!" "$OUT"
check_contains "exit of the entrypoint is intercepted" "Exit attempt intercepted." "$OUT"
check "exit status is kept in the DEBUG mode" "0" "$STATUS"

scenario
DEVICE_UDID=''
VERBOSE=true
export VERBOSE
run_entrypoint
check_contains "VERBOSE banner" "VERBOSE mode is on!" "$OUT"
check_contains "entrypoint commands are traced" "+ isConfigValid=1" "$OUT"

scenario
LOGGER_LEVEL=ERROR
DEVICE_UDID=''
run_entrypoint
check_contains "ERROR level shows errors" "[ERROR] DEVICE_UDID is required" "$OUT"
check_not_contains "ERROR level hides info" "[INFO]" "$OUT"

section "usbmuxd port"
scenario
FAKE_PORT_BUSY=1
run_entrypoint
check_contains "busy port is reported" "port is busy. Exiting!" "$OUT"
check "busy port exits with 0" "0" "$STATUS"
check "busy port is retried 10 times" "10" "$(cat "${WORK}/nc.n")"
check "usbmuxd is not started" "" "$(calls usbmuxd)"

section "usbmuxd socket"
scenario
run_entrypoint
check "own usbmuxd is started in the foreground" "-f" "$(calls usbmuxd)"
check_contains "its socket is forwarded to the port" "TCP-LISTEN:2222,reuseaddr,fork|UNIX-CONNECT:/var/run/usbmuxd" "$(calls socat)"

scenario
USBMUXD_SOCKET_ADDRESS=host.docker.internal:27015
export USBMUXD_SOCKET_ADDRESS
run_entrypoint
check "own usbmuxd is not started for USBMUXD_SOCKET_ADDRESS" "" "$(calls usbmuxd)"
check_contains "the remote socket is forwarded to the port" "TCP-LISTEN:2222,reuseaddr,fork|TCP:host.docker.internal:27015" "$(calls socat)"

scenario
USBMUXD_SOCKET_ADDRESS=unreachable:1
export USBMUXD_SOCKET_ADDRESS
stub socat 'exit 1'
run_entrypoint
check_contains "unreachable socket is reported" "Usbmuxd socket is not available. Exiting!" "$OUT"
check "unreachable socket exits with 0" "0" "$STATUS"
check "unreachable socket is retried 10 times" "10" "$(grep -c "Can't connect to USBMUXD_SOCKET_ADDRESS" <<< "$OUT")"
record_stub socat

scenario
FAKE_NC=nofwd
run_entrypoint
check_contains "missing forwarding is reported" "Usbmuxd forwarding is not established. Exiting!" "$OUT"
check "missing forwarding exits with 0" "0" "$STATUS"
check_not_contains "the device is not checked without forwarding" "Device" "$OUT"

section "device"
scenario
FAKE_DEVICE=missing
POLLING_SEC=0
run_entrypoint
check_contains "missing device is reported" "Device is not available" "$OUT"
check_contains "missing device restarts the container" "Restarting!" "$OUT"
check "missing device exits with 1" "1" "$STATUS"

scenario
FAKE_DEVICE=absent
run_entrypoint
check_contains "absent device is reported" "Device is not found '00008030-TEST'!" "$OUT"
check "absent device is polled 10 times" "10" "$(cat "${WORK}/info.n")"
check "absent device exits with 1" "1" "$STATUS"

scenario
FAKE_DEVICE=flaky
FAKE_INFO_FAILS=2
run_entrypoint
check "device is polled until it appears" "3" "$(cat "${WORK}/info.n")"
check_contains "device is available after the retries" "Device '00008030-TEST' is available." "$OUT"
check_contains "the startup goes on after the retries" "Developer Image mounted successfully." "$OUT"

scenario
FAKE_DEVICE=timeout
run_entrypoint
check_contains "timed out response is a warning" "Device reboot is recommended!" "$OUT"
check_contains "the startup continues after the timeout" "Developer Image mounted successfully." "$OUT"

section "device OS version"
scenario
run_entrypoint
check_contains "version is detected" "Detected device os version: 16.4.1" "$OUT"
check_contains "major version is detected" "Major os version detected as '16'" "$OUT"
check "iOS 16 does not start ncm" "" "$(calls go-ncm)"

scenario
FAKE_IOS_VERSION=unknown
run_entrypoint
check_contains "unknown version is a warning" "Can't detect major os version" "$OUT"

section "Developer Image"
scenario
run_entrypoint
check_contains "image is mounted" "Developer Image mounted successfully." "$OUT"
check_contains "image is mounted from the image folder" "image auto --basedir ${REPO}/devimages/ --udid=00008030-TEST" "$(calls ios)"

scenario
FAKE_IMAGE_RESULT='error mounting image'
run_entrypoint
check_contains "mount error is reported" "Unhandled exception:" "$OUT"
check "mount error exits with 0" "0" "$STATUS"

section "WDA installation"
scenario
run_entrypoint
check_contains "installed WDA is detected" "is already installed" "$OUT"
check_not_contains "installed WDA is not installed again" "install --path" "$(calls ios)"

scenario
FAKE_WDA_INSTALLED=0
run_entrypoint
check_contains "WDA is required on macOS" "Can't continue without WDA installed. Exiting!" "$OUT"
check "missing WDA on macOS exits with 0" "0" "$STATUS"

scenario
FAKE_WDA_INSTALLED=0
HOST_OS=LINUX
run_entrypoint
check_contains "WDA file is required on Linux" "file is not exist or not a regular file. Exiting!" "$OUT"
check "missing WDA file exits with 0" "0" "$STATUS"

scenario
FAKE_WDA_INSTALLED=0
HOST_OS=LINUX
touch "$WDA_FILE"
run_entrypoint
check_contains "WDA is installed from the file" "install --path=${WDA_FILE} --udid=00008030-TEST" "$(calls ios)"

section "WDA start and port forwarding"
scenario
run_entrypoint
check_contains "springboard is reset on iOS 16" "kill com.apple.springboard --udid=00008030-TEST" "$(calls ios)"
check_contains "WDA port is forwarded" "forward 8100 8100 --udid=00008030-TEST" "$(calls ios)"
check_contains "MJPEG port is forwarded" "forward 8101 8101 --udid=00008030-TEST" "$(calls ios)"
check_contains "WDA status is checked" "Wda status is OK!" "$OUT"

scenario
FAKE_IOS_VERSION=17.5
run_entrypoint
check_not_contains "springboard is not reset on iOS 17+ on macOS" "springboard" "$(calls ios)"
check_contains "ports are forwarded on iOS 17+" "forward 8100 8100" "$(calls ios)"

# count <pattern> <text>: the number of the lines of the text matching the pattern
count() {
  grep -c -- "$1" <<< "$2" || true
}

scenario
run_entrypoint
check "each port is forwarded once" "2" "$(count '^forward' "$(calls ios)")"
check_contains "lost forwarding is restored" "Port '8100' forwarding broke. Attempt to recover." "$OUT"
check_contains "restored forwarding is detected" "Port '8100' already forwarded" "$OUT"

scenario
FAKE_PGREP=never
run_entrypoint
check "broken forwarding of WDA port is retried 30 times" "30" "$(count '^forward 8100 8100' "$(calls ios)")"
check "broken forwarding of MJPEG port is retried 30 times" "30" "$(count '^forward 8101 8101' "$(calls ios)")"
check_contains "broken WDA port forwarding is reported" "Can't forward port '8100'. Restarting!" "$OUT"
check_contains "broken MJPEG port forwarding is reported" "Can't forward port '8101'. Restarting!" "$OUT"
check "broken forwarding restarts the container" "1" "$STATUS"
check_not_contains "broken forwarding ends the entrypoint before its holder checks WDA" "Wda status is BROKEN!" "$OUT"

section "WDA health"
scenario
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "unhealthy WDA is reported" "No response from WDA, or WDA is unhealthy. Restarting!" "$OUT"
check "unhealthy WDA exits with 1" "1" "$STATUS"

scenario
run_entrypoint
check_contains "lost WDA is reported" "Wda status is BROKEN!" "$OUT"
check "lost WDA exits with 1" "1" "$STATUS"

scenario
FAKE_WDA_AFTER=2
run_entrypoint
check "WDA is polled until it answers" "2" "$(count 'Bad or no response from' "$OUT")"
check_contains "late WDA becomes healthy" "Wda status is OK!" "$OUT"

scenario
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "unanswered status is retried" "Bad or no response from 'http://localhost:8100/status'. One more attempt..." "$OUT"

scenario
WDA_HOST=wda.local
WDA_PORT=9100
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "WDA_HOST and WDA_PORT are used for the status" "'http://wda.local:9100/status'" "$OUT"

scenario
run_entrypoint
check "broken WDA is tolerated 3 times and fails the 4th" "4" "$(count 'Wda status is BROKEN!' "$OUT")"

scenario
echo 1 > "${WORK}/log/background.exit"
run_entrypoint
check_contains "stale background failure is ignored" "Wda status is OK!" "$OUT"
check "stale background failure does not shorten the holder" "4" "$(count 'Wda status is BROKEN!' "$OUT")"

scenario
FAKE_FLAP=1
run_entrypoint
check "restored WDA resets the broken counter" "5" "$(count 'Wda status is BROKEN!' "$OUT")"
check "the holder reports the restored WDA" "2" "$(count 'Wda status is OK!' "$OUT")"
check "restored WDA still ends with 1" "1" "$STATUS"

section "Linux, WDA start"
scenario
HOST_OS=LINUX
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "missing WDA is detected" "Running WDA not detected." "$OUT"
check_contains "WDA is started on its port" "Starting WebDriverAgent application on port '8100'." "$OUT"
check_contains "WDA runs with the default bundle" "runwda --bundleid=com.facebook.WebDriverAgentRunner.xctrunner --testrunnerbundleid=com.facebook.WebDriverAgentRunner.xctrunner --xctestconfig=WebDriverAgentRunner.xctest" "$(calls ios)"
check_contains "WDA gets its ports" "--env USE_PORT=8100 --env MJPEG_SERVER_PORT=8101" "$(calls ios)"
check_contains "WDA gets the log file" "--log-output=${WORK}/wda.log --udid=00008030-TEST" "$(calls ios)"
check_contains "springboard is reset before WDA" "kill com.apple.springboard" "$(calls ios)"
check_contains "lost WDA process is restarted" "'ios runwda' process broke. Attempt to recover." "$OUT"
check_contains "restarted WDA is detected" "WDA already started" "$OUT"
check "WDA is started once" "1" "$(count '^runwda' "$(calls ios)")"
check_contains "ports are forwarded" "forward 8100 8100" "$(calls ios)"
check_contains "WDA becomes healthy" "Wda status is OK!" "$OUT"

scenario
HOST_OS=LINUX
FAKE_PGREP=runwda
rm "${WORK}/wda_ok"
run_entrypoint
check "WDA start is retried 10 times" "10" "$(count '^runwda' "$(calls ios)")"
check_contains "failing WDA start is reported" "Can't run WDA. Exiting!" "$OUT"
check "failing WDA start exits with 0" "0" "$STATUS"
check_not_contains "failing WDA start ends the entrypoint before its holder checks WDA" "Wda status is BROKEN!" "$OUT"

scenario
HOST_OS=LINUX
run_entrypoint
check_not_contains "running WDA is not started again" "runwda" "$(calls ios)"
check_not_contains "running WDA is not forwarded" "forward" "$(calls ios)"

scenario
HOST_OS=LINUX
rm "${WORK}/wda_ok"
TEST_RUNNER_BUNDLE_ID=com.example.runner
XCTEST_CONFIG=Custom.xctest
WDA_BUNDLEID=com.example.wda
export TEST_RUNNER_BUNDLE_ID XCTEST_CONFIG WDA_BUNDLEID
run_entrypoint
check_contains "WDA runs with the custom bundles and config" "runwda --bundleid=com.example.wda --testrunnerbundleid=com.example.runner --xctestconfig=Custom.xctest" "$(calls ios)"

scenario
HOST_OS=LINUX
FAKE_WDA_INSTALLED=0
FAKE_INSTALL=fail
touch "$WDA_FILE"
run_entrypoint
check_contains "failed WDA install is reported" "Error while installing WDA_FILE" "$OUT"
check_contains "failed WDA install is rolled back" "uninstall com.facebook.WebDriverAgentRunner.xctrunner --udid=00008030-TEST" "$(calls ios)"
check "failed WDA install exits with 0" "0" "$STATUS"

section "Linux, iOS 17+: ncm and tunnel"
scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=17.5
run_entrypoint
check "ncm is started with its metrics port" "--prometheusport=3030" "$(calls go-ncm)"
check_contains "ncm device is counted" "Found 1 device connected with ncm." "$OUT"
check_contains "tunnel is started for the device" "tunnel start --pair-record-path=/var/lib/lockdown --udid=00008030-TEST" "$(calls ios)"
check_contains "tunnel is reported" "Go-ios '/tunnels' endpoint is available:" "$OUT"
check_contains "the startup goes on after the tunnel" "Developer Image mounted successfully." "$OUT"

scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=16.4.1
run_entrypoint
check "iOS 16 on Linux has no ncm" "" "$(calls go-ncm)"
check_not_contains "iOS 16 on Linux has no tunnel" "tunnel start" "$(calls ios)"

scenario
FAKE_IOS_VERSION=17.5
run_entrypoint
check "iOS 17 on macOS has no ncm" "" "$(calls go-ncm)"
check_not_contains "iOS 17 on macOS has no tunnel" "tunnel start" "$(calls ios)"

scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=17.5
FAKE_NCM=down
run_entrypoint
check_contains "unavailable ncm metrics are reported" "Ncm '/metrics' endpoint is not available." "$OUT"
check_contains "unavailable ncm restarts the container" "Ncm can't connect with device. Restarting!" "$OUT"
check "unavailable ncm exits with 1" "1" "$STATUS"
check_not_contains "no tunnel without ncm" "tunnel start" "$(calls ios)"

scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=17.5
FAKE_NCM=zero
run_entrypoint
check_contains "ncm without devices is reported" "Found 0 device connected with ncm." "$OUT"
check "ncm without devices exits with 1" "1" "$STATUS"

scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=17.5
FAKE_TUNNEL=down
run_entrypoint
check_contains "unavailable tunnels endpoint is reported" "Go-ios '/tunnels' endpoint is not available." "$OUT"
check_contains "unavailable tunnel restarts the container" "Can't start tunnel to device. Restarting!" "$OUT"
check "unavailable tunnel exits with 1" "1" "$STATUS"

scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=17.5
FAKE_TUNNEL=nodevice
run_entrypoint
check_contains "tunnel without the device restarts the container" "Can't start tunnel to device. Restarting!" "$OUT"
check "tunnel without the device exits with 1" "1" "$STATUS"

finish
