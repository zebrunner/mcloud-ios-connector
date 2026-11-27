#!/bin/bash
# Tests of entrypoint.sh with stubs of ios, nc, socat, curl and the other tools: no device, no docker.
# The image paths (/opt/zebrunner) are replaced with the repository, the waits are stubs.
# The entrypoint needs bash 4, on macOS use the bash of brew.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

(("$(bash -c 'echo "${BASH_VERSINFO[0]}"')" >= 4)) || skip "requires bash 4 in PATH"

# a run of WDA longer than 1 second is a start (60 in the image)
sed -e "s#/opt/zebrunner/#${REPO}/#g" -e "s#/tmp/log/#${WORK}/log/#g" -e "s#/tmp/zebrunner/#${WORK}/zebrunner/#g" \
  -e "s#^lockdownDir=\"/var/lib/lockdown\"#lockdownDir=\"${WORK}/lockdown\"#" \
  -e "s#local wdaStableSec=60#local wdaStableSec=1#" entrypoint.sh > "${WORK}/entrypoint.sh"
mkdir -p "${WORK}/log" "${WORK}/zebrunner"

# the stubs read their behavior from the FAKE_* variables of the scenario
export FAKE_WORK="$WORK"
# socat: a listener (TCP-LISTEN) keeps running like the real one (its pid in socat.pids), FAKE_RELAY=stop ends it at
# once; it closes its output, so the entrypoint output is complete without waiting for it
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
socat_stub() {
  stub socat '(IFS="|"; echo "socat|$*") >> "$FAKE_WORK/calls.log"
if [[ "$1" == TCP-LISTEN:* && "$FAKE_RELAY" != stop ]]; then
  echo "$$" >> "$FAKE_WORK/socat.pids"
  exec > /dev/null 2>&1
  exec /bin/sleep 10
fi
exit 0'
}
socat_stub
record_stub usbmuxd
record_stub go-ncm
record_stub netmuxd
record_stub mcloud-ios
# jq: the pretty print of the logs is cat, the queries of the simulator (and every other one) are the real jq
realJq="$(command -v jq)"
[[ -n "$realJq" ]] || skip "requires jq"
stub jq "if [[ \"\$1\" == --raw-input ]]; then cat; else exec '${realJq}' \"\$@\"; fi"
stub hostname 'echo "172.18.0.5 fd00::5"'
stub tail 'exit 0'
# the entrypoint holder sleeps 33 seconds between the WDA checks: before the first one WDA stops answering,
# with FAKE_FLAP=1 it answers again before the second one;
# a failing background process (FAKE_PGREP is not ok) is awaited, its failure is the file with the exit code;
# FAKE_STOP=1: the first one stops the entrypoint (SIGTERM) and goes on
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub sleep 'if [[ "$1" == 33 && "$FAKE_STOP" == 1 ]]; then
  kill -TERM "$PPID"
  exec /bin/sleep 30
fi
if [[ "$1" == 33 ]]; then
  if [[ "$FAKE_PGREP" != ok ]]; then
    for _ in $(seq 300); do
      [[ -s "$FAKE_WORK/log/background.exit" || -e "$FAKE_WORK/runwda.alive" ]] && break
      /bin/sleep 0.1
    done
  fi
  n=$(cat "$FAKE_WORK/sleep33.n" 2> /dev/null || echo 0)
  echo $((n + 1)) > "$FAKE_WORK/sleep33.n"
  if [[ "$FAKE_FLAP" == 1 && "$n" == 1 ]]; then touch "$FAKE_WORK/wda_ok"; else rm -f "$FAKE_WORK/wda_ok"; fi
fi
exit 0'
# nc: the first call checks that the usbmuxd port is free, the next ones that it is forwarded
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub nc 'n=$(cat "$FAKE_WORK/nc.n" 2> /dev/null || echo 0); echo $((n + 1)) > "$FAKE_WORK/nc.n"
[[ "$FAKE_PORT_BUSY" == 1 ]] && exit 0
[[ "$FAKE_NC" == nofwd ]] && exit 1
[[ "$n" -gt 0 ]]'
# curl: the metrics of go-ncm (FAKE_NCM), the tunnels of go-ios (FAKE_TUNNEL) and the status of WDA (the wda_ok file),
# FAKE_WDA_AFTER is the number of the status requests WDA does not answer yet
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
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
      case "$FAKE_TUNNEL" in
        nodevice) echo "[]" ;;
        noport) echo "[{\"udid\":\"${DEVICE_UDID}\",\"userspaceTun\":true,\"userspaceTunPort\":0}]" ;;
        *) echo "[{\"udid\":\"${DEVICE_UDID}\",\"userspaceTun\":true,\"userspaceTunPort\":60106}]" ;;
      esac
    fi ;;
  */status*)
    [[ -e "$FAKE_WORK/wda_ok" ]] || { echo 000; exit 0; }
    n=$(cat "$FAKE_WORK/curl.n" 2> /dev/null || echo 0)
    echo $((n + 1)) > "$FAKE_WORK/curl.n"
    if [[ "$n" -ge "$FAKE_WDA_AFTER" ]]; then echo 200; else echo 000; fi ;;
esac
exit 0'
# pgrep: a process is missing on the first check of its pattern and running on the next ones,
# FAKE_PGREP=never: always missing, FAKE_PGREP=runwda: ios runwda is missing until it keeps running (FAKE_RUNWDA=late)
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub pgrep '[[ "$FAKE_PGREP" == never ]] && exit 1
[[ "$FAKE_PGREP" == runwda && "$*" == *"ios runwda"* && ! -e "$FAKE_WORK/runwda.alive" ]] && exit 1
f="$FAKE_WORK/pgrep-$(echo "$*" | tr -c "a-z0-9" _)"
[[ -e "$f" ]] && exit 0
touch "$f"
exit 1'
# ios: runwda starts WDA (the wda_ok file), FAKE_RUNWDA: signature, nostart, late; image mount (of DDI_DIR) answers
# FAKE_DDI_MOUNT_RESULT, image auto FAKE_IMAGE_RESULT; reboot (counted in reboot.n) by FAKE_REBOOT: usb (the device
# leaves the list), silent (it stays in the list and stops answering: netmuxd), boot (only its boot time of ps changes),
# noop (nothing happens), once (the first one is a noop); FAKE_PS=none: ps answers nothing
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub ios 'echo "ios|$*" >> "$FAKE_WORK/calls.log"
[[ -n "$GO_IOS_AGENT_HOST" ]] && echo "$1|$GO_IOS_AGENT_HOST" >> "$FAKE_WORK/agent.log"
reboots=$(cat "$FAKE_WORK/reboot.n" 2> /dev/null || echo 0)
rebooted=""
case "$FAKE_REBOOT" in
  noop) ;;
  once) [[ "$reboots" -ge 2 ]] && rebooted="usb" ;;
  *) [[ "$reboots" -ge 1 ]] && rebooted="$FAKE_REBOOT" ;;
esac
case "$1" in
  reboot)
    echo $((reboots + 1)) > "$FAKE_WORK/reboot.n"
    echo "{\"level\":\"info\",\"msg\":\"ok\"}" ;;
  list)
    if [[ "$rebooted" == usb ]]; then echo "{\"deviceList\":[]}"; else echo "{\"deviceList\":[\"${DEVICE_UDID}\"]}"; fi ;;
  ps)
    [[ "$FAKE_PS" == none || "$rebooted" == silent ]] && exit 1
    boot="2026-11-07T08:00:00Z"
    [[ "$rebooted" == boot ]] && boot="2026-11-27T10:00:00.25Z"
    echo "[{\"Name\":\"kernel_task\",\"Pid\":0,\"StartDate\":\"0001-01-01T00:00:00Z\"},{\"Name\":\"launchd\",\"Pid\":1,\"StartDate\":\"${boot}\"},{\"Name\":\"SpringBoard\",\"Pid\":40,\"StartDate\":\"2026-11-27T11:00:00Z\"}]" ;;
  info)
    [[ "$rebooted" == silent ]] && { echo "failed getting info"; exit 1; }
    n=$(cat "$FAKE_WORK/info.n" 2> /dev/null || echo 0)
    echo $((n + 1)) > "$FAKE_WORK/info.n"
    [[ "$FAKE_DEVICE" == flaky && "$n" -lt "$FAKE_INFO_FAILS" ]] && { echo "device not found"; exit 1; }
    [[ "$FAKE_DEVICE" == absent ]] && { echo "device not found"; exit 1; }
    [[ "$FAKE_DEVICE" == missing ]] && { echo "failed getting info"; exit 1; }
    # paired: answers with the pair record of the lockdown folder only; untrusted: the device refuses the record,
    # usbmuxd removes it
    record="$FAKE_WORK/lockdown/${DEVICE_UDID}.plist"
    [[ "$FAKE_DEVICE" == untrusted ]] && rm -f "$record"
    [[ ("$FAKE_DEVICE" == paired || "$FAKE_DEVICE" == untrusted) && ! -e "$record" ]] &&
      { echo "{\"err\":\"could not retrieve PairRecord with error: ReadPair failed with errorcode 2, is the device paired?\",\"level\":\"fatal\",\"msg\":\"failed getting info\"}"; exit 1; }
    [[ "$FAKE_DEVICE" == timeout || ("$FAKE_DEVICE" == slow && "$n" -lt "$FAKE_INFO_FAILS") ]] &&
      { echo "Timed out waiting for response for message:5 channel:0"; exit 1; }
    class=""
    [[ -n "$FAKE_DEVICE_CLASS" ]] && class=",\"DeviceClass\":\"${FAKE_DEVICE_CLASS}\""
    passcode=""
    [[ "$FAKE_PASSCODE" == 1 ]] && passcode=",\"PasswordProtected\":true"
    echo "{\"ProductVersion\":\"${FAKE_IOS_VERSION}\"${class}${passcode}}" ;;
  image) [[ "$2" == mount ]] && echo "${FAKE_DDI_MOUNT_RESULT}" || echo "${FAKE_IMAGE_RESULT}" ;;
  apps) [[ "$FAKE_WDA_INSTALLED" == 1 ]] && echo "${WDA_BUNDLEID}" ;;
  install) [[ "$FAKE_INSTALL" == fail ]] && echo "{\"err\":\"install failed\"}" ;;
  runwda)
    if [[ "$FAKE_RUNWDA" == signature ]]; then
      echo "Unable to launch com.facebook.WebDriverAgentRunner.xctrunner because it has an invalid code signature"
      exit 1
    fi
    # late: WDA runs for 2.2 s and ends 11 times, then it keeps running
    if [[ "$FAKE_RUNWDA" == late ]]; then
      n=$(cat "$FAKE_WORK/runwda.n" 2> /dev/null || echo 0)
      echo $((n + 1)) > "$FAKE_WORK/runwda.n"
      [[ "$n" -ge 11 ]] && touch "$FAKE_WORK/runwda.alive"
      /bin/sleep 2.2
    fi
    # hang: testmanagerd of the device does not answer, WDA does not start
    if [[ "$FAKE_RUNWDA" == hang ]]; then
      echo "{\"level\":\"ERROR\",\"msg\":\"failed requesting channel\",\"module\":\"go-ios/dtx_codec\",\"channel_id\":\"dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface\",\"error\":\"Timed out waiting for response for message:5 channel:0\"}"
      echo "{\"level\":\"ERROR\",\"msg\":\"Failed running WDA\",\"error\":\"RunXUITestWithBundleIdsXcode12Ctx: cannot initiate a control session with capabilities: Timed out waiting for response for message:1 channel:1\"}"
      exit 1
    fi
    [[ "$FAKE_RUNWDA" == nostart ]] || touch "$FAKE_WORK/wda_ok" ;;
esac
exit 0'
# ssh: the macOS host of the simulators, FAKE_SSH (ok, denied, down), FAKE_SIM_* the simulator,
# the launch of WDA starts it (the wda_ok file)
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub ssh 'echo "ssh|$*" >> "$FAKE_WORK/calls.log"
[[ "$*" == *"tar -xf -"* ]] && cat > /dev/null
case "$FAKE_SSH" in
  denied) echo "user@host: Permission denied (publickey)."; exit 255 ;;
  down) echo "ssh: connect to host host.docker.internal port 22: Connection refused"; exit 255 ;;
esac
case "$*" in
  *"simctl list devices"*)
    echo "{\"devices\":{\"${FAKE_SIM_RUNTIME}\":[{\"udid\":\"${FAKE_SIM_UDID}\",\"state\":\"Shutdown\",\"name\":\"Sim\",\"deviceTypeIdentifier\":\"${FAKE_SIM_TYPE}\"}]}}" ;;
  *bootstatus*) [[ "$FAKE_SIM_BOOT" == fail ]] && { echo "Unable to boot"; exit 1; } ;;
  *get_app_container*) [[ "$FAKE_WDA_INSTALLED" == 1 ]] || exit 2 ;;
  *"simctl install"*) [[ "$FAKE_INSTALL" == fail ]] && { echo "install failed"; exit 1; } ;;
  *"simctl launch"*)
    [[ "$FAKE_SIM_LAUNCH" == fail ]] && { echo "launch failed"; exit 1; }
    touch "$FAKE_WORK/wda_ok"; echo "${DEVICE_UDID}: 4242" ;;
esac
exit 0'

# scenario <name>: a fresh state, a healthy iOS 16 device on macOS (HOST_OS=DARWIN) with WDA installed by default
scenario() {
  rm -f "${WORK}/agent.log" "${WORK}"/zebrunner/* "${WORK}"/*.n "${WORK}/runwda.alive" "${WORK}"/nc.n "${WORK}"/log/* "${WORK}/WebDriverAgent.ipa" "${WORK}"/pgrep-* "${WORK}/wda_ok"
  touch "${WORK}/wda_ok"
  reset_calls
  FAKE_PORT_BUSY=0
  FAKE_DEVICE=ok
  FAKE_IOS_VERSION=16.4.1
  FAKE_IMAGE_RESULT='success mounting image'
  FAKE_DDI_MOUNT_RESULT='success mounting image'
  FAKE_WDA_INSTALLED=1
  FAKE_INSTALL=ok
  FAKE_NCM=ok
  FAKE_TUNNEL=ok
  FAKE_NC=ok
  FAKE_PGREP=ok
  FAKE_FLAP=0
  FAKE_WDA_AFTER=0
  FAKE_INFO_FAILS=0
  FAKE_DEVICE_CLASS=iPhone
  FAKE_RUNWDA=ok
  FAKE_SSH=ok
  FAKE_RELAY=run
  FAKE_SIM_UDID=00008030-TEST
  FAKE_SIM_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-18-5
  FAKE_SIM_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-16
  FAKE_SIM_BOOT=ok
  FAKE_SIM_LAUNCH=ok
  FAKE_STOP=0
  FAKE_REBOOT=usb
  FAKE_PS=ok
  export FAKE_REBOOT FAKE_PS
  DEVICE_UNAVAILABLE_TIMEOUT=600
  export FAKE_STOP FAKE_SSH FAKE_RELAY FAKE_SIM_UDID FAKE_SIM_RUNTIME FAKE_SIM_TYPE FAKE_SIM_BOOT FAKE_SIM_LAUNCH
  export FAKE_NC FAKE_PGREP FAKE_FLAP FAKE_WDA_AFTER FAKE_INFO_FAILS FAKE_DEVICE_CLASS FAKE_RUNWDA DEVICE_UNAVAILABLE_TIMEOUT
  export FAKE_PORT_BUSY FAKE_DEVICE FAKE_IOS_VERSION FAKE_IMAGE_RESULT FAKE_WDA_INSTALLED FAKE_INSTALL FAKE_NCM FAKE_TUNNEL
  export FAKE_DDI_MOUNT_RESULT DDI_DIR="${WORK}/ddi"
  rm -rf "${WORK}/ddi"
  export HOST_OS=DARWIN DEVICE_UDID=00008030-TEST POLLING_SEC=0 USBMUXD_PORT=2222 USBMUXD_SOCKET_ADDRESS=''
  export WDA_HOST=localhost WDA_PORT=8100 MJPEG_PORT=8101 WDA_WAIT_TIMEOUT=2
  export WDA_BUNDLEID=com.facebook.WebDriverAgentRunner.xctrunner WDA_LOG_FILE="${WORK}/wda.log"
  export WDA_FILE="${WORK}/WebDriverAgent.ipa" LOGGER_LEVEL=DEBUG
  export DEVICE_CONNECTION=usb DEVICE_ADDRESS='' HOST_SSH_USER=builder HOST_SSH_HOST=host.docker.internal HOST_SSH_PORT=22
  export HOST_SSH_PROXY_PORT=22 HOST_SSH_KEY="${WORK}/id_ed25519"
  echo key > "${WORK}/id_ed25519"
  rm -rf "${WORK}/lockdown"
  unset DEBUG VERBOSE TEST_RUNNER_BUNDLE_ID XCTEST_CONFIG DEVICE_WDA_PORT DEVICE_MJPEG_PORT
  unset ALLOW_REBOOT WDA_FAILURES_BEFORE_REBOOT REBOOT_INTERVAL WDA_BIND_ADDRESS REBOOT_CONFIRM_TIMEOUT
  export FAKE_PASSCODE=0
}

# sim_scenario: the scenario of a simulator, its udid is a UUID
sim_scenario() {
  scenario
  DEVICE_CONNECTION=ios-sim
  DEVICE_UDID=6A1C8E2B-4F3D-4E5A-9B7C-1D2E3F4A5B6C
  FAKE_SIM_UDID="$DEVICE_UDID"
}

# run_entrypoint: output of the entrypoint in $OUT, its exit status in $STATUS
run_entrypoint() {
  OUT="$(PATH="${WORK}/bin:${PATH}" bash "${WORK}/entrypoint.sh" 2>&1)"
  STATUS=$?
}

# rerun_entrypoint [nowda]: the next start of the same container: the state of the stubs is reset (WDA answers, nowda:
# it does not), the files of the container (/tmp/zebrunner) and the lockdown volume are kept
rerun_entrypoint() {
  rm -f "${WORK}"/*.n "${WORK}/runwda.alive" "${WORK}"/log/* "${WORK}"/pgrep-* "${WORK}/wda_ok"
  [[ "$1" == nowda ]] || touch "${WORK}/wda_ok"
  reset_calls
  run_entrypoint
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

for var in POLLING_SEC USBMUXD_PORT WDA_PORT MJPEG_PORT WDA_WAIT_TIMEOUT DEVICE_UNAVAILABLE_TIMEOUT; do
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
socat_stub

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

section "device unavailable for long (unpaired)"
marker="${WORK}/zebrunner/device-unavailable-since"
scenario
FAKE_DEVICE=absent
run_entrypoint
check "first unavailable run restarts" "1" "$STATUS"
check "first unavailable run records the time" "true" "$([[ "$(cat "$marker" 2> /dev/null)" =~ ^[0-9]+$ ]] && echo true || echo false)"

scenario
FAKE_DEVICE=absent
seed=$(($(date +%s) - 10))
echo "$seed" > "$marker"
run_entrypoint
check "short unavailability restarts" "1" "$STATUS"
check_contains "short unavailability asks for restart" "Restarting!" "$OUT"
check "the recorded time is kept" "$seed" "$(cat "$marker")"

scenario
FAKE_DEVICE=absent
echo $(($(date +%s) - 700)) > "$marker"
run_entrypoint
check "long unavailability exits with 0" "0" "$STATUS"
check_contains "long unavailability is reported" "Device is unavailable for 70" "$OUT"
check_contains "long unavailability stops the restarts" "(not more than 600 allowed, is it unpaired?). Exiting!" "$OUT"
check_not_contains "long unavailability does not ask for restart" "Restarting!" "$OUT"

scenario
FAKE_DEVICE=absent
DEVICE_UNAVAILABLE_TIMEOUT=0
echo $(($(date +%s) - 100000)) > "$marker"
run_entrypoint
check "zero timeout restarts forever" "1" "$STATUS"

scenario
FAKE_DEVICE=absent
DEVICE_UNAVAILABLE_TIMEOUT=60
echo $(($(date +%s) - 40)) > "$marker"
run_entrypoint
check "unavailability just below the timeout restarts" "1" "$STATUS"

scenario
FAKE_DEVICE=absent
echo garbage > "$marker"
run_entrypoint
check "broken record restarts" "1" "$STATUS"
check "broken record is replaced" "true" "$([[ "$(cat "$marker")" =~ ^[0-9]+$ ]] && echo true || echo false)"

scenario
echo $(($(date +%s) - 700)) > "$marker"
run_entrypoint
check "available device removes the record" "false" "$([[ -e "$marker" ]] && echo true || echo false)"
check_contains "available device is not stopped by the old record" "Developer Image mounted successfully." "$OUT"

scenario
FAKE_DEVICE=timeout
echo $(($(date +%s) - 700)) > "$marker"
run_entrypoint
check "timed out device keeps the record" "true" "$([[ -e "$marker" ]] && echo true || echo false)"
check "timed out device for too long exits with 0" "0" "$STATUS"

scenario
FAKE_DEVICE=slow
FAKE_INFO_FAILS=2
echo $(($(date +%s) - 700)) > "$marker"
run_entrypoint
check "slow device removes the record when it answers" "false" "$([[ -e "$marker" ]] && echo true || echo false)"

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
check "timed out device is polled 10 times" "10" "$(cat "${WORK}/info.n")"
check_not_contains "timed out device does not start without its info" "Detected device os version" "$OUT"
check "timed out device exits with 1" "1" "$STATUS"

scenario
FAKE_DEVICE=slow
FAKE_INFO_FAILS=2
FAKE_IOS_VERSION=17.5
run_entrypoint
check "slow device is polled until it answers" "3" "$(cat "${WORK}/info.n")"
check_contains "slow device starts with its version" "Major os version detected as '17'" "$OUT"
check_contains "the startup goes on after the timeouts" "Developer Image mounted successfully." "$OUT"

section "pair record backup"
record="${WORK}/lockdown/00008030-TEST.plist"
backup="${WORK}/lockdown/backup/00008030-TEST.plist"
restores="${WORK}/lockdown/backup/00008030-TEST.restores"
# mode <file>: the permissions of the file, octal
mode() {
  stat -c '%a' "$1" 2> /dev/null || stat -f '%Lp' "$1"
}

scenario
FAKE_DEVICE=paired
mkdir -p "${WORK}/lockdown"
echo record-1 > "$record"
run_entrypoint
check "the record of the device that answered is backed up" "record-1" "$(cat "$backup" 2> /dev/null)"
check "the backup is a secret" "600" "$(mode "$backup")"
check "the backup folder is a secret" "700" "$(mode "${WORK}/lockdown/backup")"
check_contains "the backup is reported" "The pair record of '00008030-TEST' is backed up" "$OUT"
rerun_entrypoint
check_contains "the device starts again" "Developer Image mounted successfully." "$OUT"
check_not_contains "an unchanged record is not backed up again" "is backed up" "$OUT"
echo record-2 > "$record"
rerun_entrypoint
check "the backup follows a new pairing" "record-2" "$(cat "$backup")"

scenario
FAKE_DEVICE=paired
mkdir -p "${WORK}/lockdown/backup"
echo record-1 > "$backup"
run_entrypoint
check "a missing record is restored before usbmuxd starts" "record-1" "$(cat "$record" 2> /dev/null)"
check "the restored record is a secret" "600" "$(mode "$record")"
check_contains "the restore is reported" "was removed (usbmuxd: an SSL error of StartSession, e.g. a USB drop); restored from the backup of" "$OUT"
check_contains "the device starts with the restored record" "Developer Image mounted successfully." "$OUT"
check "the answer of the device resets the restores" "false" "$([[ -e "$restores" ]] && echo true || echo false)"
check "the restore precedes usbmuxd" "true" \
  "$([[ "$(grep -n "restored from the backup" <<< "$OUT" | cut -d: -f1)" -lt "$(grep -n "Start containerized usbmuxd" <<< "$OUT" | cut -d: -f1)" ]] && echo true || echo false)"

scenario
FAKE_DEVICE=untrusted
mkdir -p "${WORK}/lockdown/backup"
echo record-1 > "$record"
echo record-1 > "$backup"
run_entrypoint
check_contains "a record removed in this start is restored" "Restarting with the restored pair record!" "$OUT"
check "a record removed in this start asks for a restart" "1" "$STATUS"
check "the record is back for the next start" "record-1" "$(cat "$record" 2> /dev/null)"
check "the restore is counted" "1" "$(cat "$restores" 2> /dev/null)"
rerun_entrypoint
rerun_entrypoint
check "the restores are counted over the starts" "3" "$(cat "$restores" 2> /dev/null)"
rerun_entrypoint
check_contains "a record the device refuses is rejected" "was removed 3 times: the device does not trust this host" "$OUT"
check "the rejected backup is not restored" "false" "$([[ -e "$backup" || -e "$record" ]] && echo true || echo false)"
check "the rejected backup is kept" "1" "$(find "${WORK}/lockdown/backup" -name '00008030-TEST.plist.rejected-*' | wc -l | tr -d ' ')"
check_contains "the person is asked to trust the host" "Unlock it and accept the Trust dialog (docker exec <connector> ios pair --udid=00008030-TEST)" "$OUT"
check_contains "the missing record is reported" "No pair record of '00008030-TEST'." "$OUT"
check "the untrusted device restarts within its budget" "1" "$STATUS"
rerun_entrypoint
check_contains "the next start reaches the device" "Usbmuxd forwarding established." "$OUT"
check_not_contains "a rejected backup is not restored again" "restored from the backup" "$OUT"

scenario
FAKE_DEVICE=paired
run_entrypoint
check_not_contains "without a backup nothing is restored" "restored from the backup" "$OUT"
check_contains "without a backup the person is asked to trust the host" "accept the Trust dialog" "$OUT"
check "without a backup the device restarts within its budget" "1" "$STATUS"

scenario
mkdir -p "${WORK}/lockdown"
echo record-1 > "$record"
USBMUXD_SOCKET_ADDRESS=host.docker.internal:27015
export USBMUXD_SOCKET_ADDRESS
run_entrypoint
check "the records of the usbmuxd of the host are not backed up" "false" "$([[ -e "$backup" ]] && echo true || echo false)"
rm -f "$record"
mkdir -p "${WORK}/lockdown/backup"
echo record-1 > "$backup"
rerun_entrypoint
check "the records of the usbmuxd of the host are not restored" "false" "$([[ -e "$record" ]] && echo true || echo false)"

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

image_marker="${WORK}/zebrunner/image-mount-failing-since"
scenario
FAKE_IMAGE_RESULT='error mounting image'
run_entrypoint
check_contains "mount error is reported" "Developer Image is not mounted." "$OUT"
check "mount error restarts" "1" "$STATUS"
check "mount error records the time" "true" "$([[ "$(cat "$image_marker" 2> /dev/null)" =~ ^[0-9]+$ ]] && echo true || echo false)"

scenario
FAKE_IMAGE_RESULT='error mounting image'
echo $(($(date +%s) - 700)) > "$image_marker"
run_entrypoint
check "lasting mount error exits with 0" "0" "$STATUS"
check_contains "lasting mount error stops the restarts" "Developer Image is not mounted for 70" "$OUT"

scenario
echo $(($(date +%s) - 700)) > "$image_marker"
run_entrypoint
check "mounted image forgets the failures" "false" "$([[ -e "$image_marker" ]] && echo true || echo false)"

section "Developer Disk Images of DDI_DIR"
# fake_ddi <file...>: the files of a checkout of zebrunner/DeveloperDiskImage in DDI_DIR
fake_ddi() {
  local file
  for file in "$@"; do
    mkdir -p "$(dirname "${WORK}/ddi/${file}")"
    echo image > "${WORK}/ddi/${file}"
  done
}
# fake_ddi_versions <version...>: the images of iOS before 17 with their signatures
fake_ddi_versions() {
  local version
  for version in "$@"; do
    fake_ddi "DeveloperDiskImages/${version}/DeveloperDiskImage.dmg" "DeveloperDiskImages/${version}/DeveloperDiskImage.dmg.signature"
  done
}
fake_ddi_personalized() {
  fake_ddi PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist PersonalizedImages/Xcode_tvOS_DDI_Personalized/BuildManifest.plist
}
ddi="${WORK}/ddi"

scenario
run_entrypoint
check_not_contains "without DDI_DIR nothing is mounted from it" "image mount" "$(calls ios)"
check_not_contains "without DDI_DIR nothing is reported about it" "DDI_DIR" "$OUT"
check_contains "without DDI_DIR the source is go-ios" "Developer Image source: go-ios" "$OUT"

scenario
fake_ddi_versions 16.4.1 16.4 16.5
run_entrypoint
check "the image of the exact version is mounted" "image mount --path=${ddi}/DeveloperDiskImages/16.4.1/DeveloperDiskImage.dmg --udid=00008030-TEST" "$(calls ios | grep '^image')"
check_contains "the image of DDI_DIR is the source" "Developer Image source: DDI_DIR '${ddi}/DeveloperDiskImages/16.4.1/DeveloperDiskImage.dmg'." "$OUT"
check_contains "the image of DDI_DIR is mounted" "Developer Image mounted successfully." "$OUT"

scenario
fake_ddi_versions 16.3 16.4 16.5
run_entrypoint
check "the image of major.minor is mounted" "image mount --path=${ddi}/DeveloperDiskImages/16.4/DeveloperDiskImage.dmg --udid=00008030-TEST" "$(calls ios | grep '^image')"

scenario
FAKE_IOS_VERSION=12.5.7
fake_ddi_versions 11.4 12.3 12.4 13.0
run_entrypoint
check "the newest lower image of the major is mounted" "image mount --path=${ddi}/DeveloperDiskImages/12.4/DeveloperDiskImage.dmg --udid=00008030-TEST" "$(calls ios | grep '^image')"

scenario
FAKE_IOS_VERSION=16.4
fake_ddi DeveloperDiskImages/16.4/DeveloperDiskImage.dmg
fake_ddi_personalized
run_entrypoint
check "an image without its signature is downloaded" "image auto --basedir ${REPO}/devimages/ --udid=00008030-TEST" "$(calls ios | grep '^image')"
check_contains "an image of another version is reported" "DDI_DIR '${ddi}' has no Developer Image of Phone 16.4, trying the one of go-ios." "$OUT"

scenario
FAKE_IOS_VERSION=10.3.4
fake_ddi_versions 11.4 12.0
run_entrypoint
check "a version older than the images of DDI_DIR is downloaded" "image auto --basedir ${REPO}/devimages/ --udid=00008030-TEST" "$(calls ios | grep '^image')"

scenario
FAKE_IOS_VERSION=17.5
fake_ddi_personalized
run_entrypoint
check "the personalized image of iOS is mounted on iOS 17+" "image mount --path=${ddi}/PersonalizedImages/Xcode_iOS_DDI_Personalized --udid=00008030-TEST" "$(calls ios | grep '^image')"
check_contains "the personalized image is mounted" "Developer Image mounted successfully." "$OUT"

scenario
FAKE_IOS_VERSION=26.1
FAKE_DEVICE_CLASS=AppleTV
fake_ddi_personalized
run_entrypoint
check "the personalized image of tvOS is mounted on an Apple TV" "image mount --path=${ddi}/PersonalizedImages/Xcode_tvOS_DDI_Personalized --udid=00008030-TEST" "$(calls ios | grep '^image')"

scenario
FAKE_IOS_VERSION=17.5
FAKE_DEVICE_CLASS=AppleTV
fake_ddi PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist
run_entrypoint
check "an Apple TV never gets the image of iOS" "image auto --basedir ${REPO}/devimages/ --udid=00008030-TEST" "$(calls ios | grep '^image')"

scenario
FAKE_IOS_VERSION=16.4
FAKE_DEVICE_CLASS=AppleTV
fake_ddi_versions 16.4
run_entrypoint
check "tvOS before 17 is downloaded (the images of DDI_DIR are of iOS)" "image auto --basedir ${REPO}/devimages/ --udid=00008030-TEST" "$(calls ios | grep '^image')"

scenario
FAKE_IOS_VERSION=17.5
fake_ddi_versions 16.7
run_entrypoint
check "iOS 17+ without the personalized image is downloaded" "image auto --basedir ${REPO}/devimages/ --udid=00008030-TEST" "$(calls ios | grep '^image')"

scenario
fake_ddi_versions 16.4
FAKE_DDI_MOUNT_RESULT='error mounting image'
run_entrypoint
check "a failed mount of DDI_DIR is followed by go-ios" "2" "$(calls ios | grep -c '^image')"
check_contains "a failed mount of DDI_DIR goes on with go-ios" "image auto --basedir ${REPO}/devimages/" "$(calls ios)"
check_contains "a failed mount of DDI_DIR is reported" "The Developer Image of DDI_DIR is not mounted, trying the one of go-ios." "$OUT"
check_contains "the image of go-ios is the source then" "Developer Image source: go-ios" "$OUT"
check "the image of go-ios is mounted then" "true" "$([[ "$OUT" == *"Developer Image mounted successfully."* ]] && echo true || echo false)"

scenario
fake_ddi_versions 16.4
FAKE_DDI_MOUNT_RESULT='error mounting image'
FAKE_IMAGE_RESULT='error mounting image'
run_entrypoint
check "failed mounts of both sources restart" "1" "$STATUS"

section "WDA installation"
scenario
run_entrypoint
check_contains "installed WDA is detected" "is already installed" "$OUT"
check_not_contains "installed WDA is not installed again" "install --path" "$(calls ios)"

scenario
FAKE_WDA_INSTALLED=0
run_entrypoint
check_contains "WDA file is required on macOS" "file is not exist or not a regular file. Exiting!" "$OUT"
check "missing WDA file on macOS exits with 0" "0" "$STATUS"

scenario
FAKE_WDA_INSTALLED=0
touch "$WDA_FILE"
run_entrypoint
check_contains "WDA is installed from the file on macOS" "install --path=${WDA_FILE} --udid=00008030-TEST" "$(calls ios)"

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
FAKE_RUNWDA=nostart
run_entrypoint
check_contains "unhealthy WDA is reported" "No response from WDA, or WDA is unhealthy. Restarting!" "$OUT"
check "unhealthy WDA exits with 1" "1" "$STATUS"

scenario
run_entrypoint
check_contains "lost WDA is reported" "Wda status is BROKEN!" "$OUT"
check "lost WDA exits with 1" "1" "$STATUS"

scenario
HOST_OS=LINUX
FAKE_WDA_AFTER=3
run_entrypoint
check "WDA is polled until it answers" "2" "$(count 'Bad or no response from' "$OUT")"
check_contains "late WDA becomes healthy" "Wda status is OK!" "$OUT"

scenario
rm "${WORK}/wda_ok"
FAKE_RUNWDA=nostart
run_entrypoint
check_contains "unanswered status is retried" "Bad or no response from 'http://localhost:8100/status'. One more attempt..." "$OUT"

scenario
WDA_HOST=wda.local
WDA_PORT=9100
rm "${WORK}/wda_ok"
FAKE_RUNWDA=nostart
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
check_contains "WDA of a usb device listens on the loopback" "--env MJPEG_SERVER_PORT=8101 --env USE_IP=127.0.0.1 --env UITEST_DISABLE_ANIMATIONS=YES" "$(calls ios)"
check_contains "the address of WDA is logged" "WebDriverAgent listens on 127.0.0.1 only (USE_IP, WDA_BIND_ADDRESS=auto)" "$OUT"
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
FAKE_PGREP=runwda
FAKE_RUNWDA=late
rm "${WORK}/wda_ok"
run_entrypoint
check "WDA that ran before it ended is started again past 10 times" "true" \
  "$([[ "$(count '^runwda' "$(calls ios)")" -gt 10 ]] && echo true || echo false)"
check_not_contains "WDA that ran before it ended does not stop the container" "Can't run WDA. Exiting!" "$OUT"

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

section "WDA address"
for value in all ALL; do
  scenario
  HOST_OS=LINUX
  WDA_BIND_ADDRESS=$value
  export WDA_BIND_ADDRESS
  rm "${WORK}/wda_ok"
  run_entrypoint
  check_not_contains "WDA_BIND_ADDRESS=${value}: WDA listens on every interface" "USE_IP" "$(calls ios)"
  check_contains "WDA_BIND_ADDRESS=${value} is warned" "WebDriverAgent listens on all the interfaces, it has no authentication (WDA_BIND_ADDRESS=all)." "$OUT"
  check_contains "WDA_BIND_ADDRESS=${value}: WDA becomes healthy" "Wda status is OK!" "$OUT"
done

for value in 10.0.0.7 fd72:3e3:926f::1 ::1; do
  scenario
  HOST_OS=LINUX
  WDA_BIND_ADDRESS=$value
  export WDA_BIND_ADDRESS
  rm "${WORK}/wda_ok"
  run_entrypoint
  check_contains "WDA_BIND_ADDRESS=${value} is passed as is" "--env USE_IP=${value} --env" "$(calls ios)"
done

for value in "" auto Auto; do
  scenario
  HOST_OS=LINUX
  WDA_BIND_ADDRESS=$value
  export WDA_BIND_ADDRESS
  rm "${WORK}/wda_ok"
  run_entrypoint
  check_contains "WDA_BIND_ADDRESS='${value}' is auto" "--env USE_IP=127.0.0.1" "$(calls ios)"
done

# a command substitution is not expanded: the address is a part of the commands of the macOS host
# shellcheck disable=SC2016
for value in localhost "127.0.0.1; true" "1.2.3" '$(id)' "0.0.0.0 x" any; do
  scenario
  WDA_BIND_ADDRESS=$value
  export WDA_BIND_ADDRESS
  run_entrypoint
  check_contains "WDA_BIND_ADDRESS='${value}' is reported" "WDA_BIND_ADDRESS must be auto, all or an IP address, but it is '${value,,}'." "$OUT"
  check "WDA_BIND_ADDRESS='${value}' exits with 0" "0" "$STATUS"
  check "nothing is started with WDA_BIND_ADDRESS='${value}'" "" "$(calls ios)$(calls socat)$(calls usbmuxd)"
done

scenario
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "WDA of a usb device on macOS listens on the loopback" "--env USE_IP=127.0.0.1" "$(calls ios)"

scenario
run_entrypoint
check_contains "WDA of the host is not bound by the connector" "WDA started outside the container is used (WDA_BIND_ADDRESS does not apply to it)." "$OUT"

section "device type"
scenario
run_entrypoint
check_contains "iPhone is a Phone" "Detected device class: 'iPhone', device type: 'Phone'" "$OUT"

scenario
FAKE_DEVICE_CLASS=iPad
run_entrypoint
check_contains "iPad is a Tablet" "Detected device class: 'iPad', device type: 'Tablet'" "$OUT"

scenario
FAKE_DEVICE_CLASS=AppleTV
run_entrypoint
check_contains "AppleTV is tvOS" "Detected device class: 'AppleTV', device type: 'tvOS'" "$OUT"
check_contains "tvOS gets its xctest config" "XCTEST_CONFIG is not set, using 'WebDriverAgentRunner_tvOS.xctest' for tvOS." "$OUT"

scenario
FAKE_DEVICE_CLASS=''
run_entrypoint
check_contains "missing class is a Phone" "device type: 'Phone'" "$OUT"

scenario
FAKE_DEVICE_CLASS=iPod
run_entrypoint
check_contains "iPod is a Phone" "Detected device class: 'iPod', device type: 'Phone'" "$OUT"

for class in iPhone iPad iPod; do
  scenario
  HOST_OS=LINUX
  FAKE_DEVICE_CLASS=$class
  rm "${WORK}/wda_ok"
  run_entrypoint
  check_contains "${class} runs WDA with the default xctest config" "--xctestconfig=WebDriverAgentRunner.xctest" "$(calls ios)"
done

scenario
HOST_OS=LINUX
FAKE_DEVICE_CLASS=AppleTV
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "tvOS runs WDA with the tvOS xctest config" "runwda --bundleid=com.facebook.WebDriverAgentRunner.xctrunner --testrunnerbundleid=com.facebook.WebDriverAgentRunner.xctrunner --xctestconfig=WebDriverAgentRunner_tvOS.xctest" "$(calls ios)"

scenario
HOST_OS=LINUX
FAKE_DEVICE_CLASS=AppleTV
XCTEST_CONFIG=Custom.xctest
export XCTEST_CONFIG
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "manual XCTEST_CONFIG is kept on tvOS" "--xctestconfig=Custom.xctest" "$(calls ios)"
check_not_contains "manual XCTEST_CONFIG is not reported as replaced" "XCTEST_CONFIG is not set" "$OUT"

scenario
HOST_OS=LINUX
FAKE_DEVICE_CLASS=AppleTV
WDA_BUNDLEID=com.example.wda
TEST_RUNNER_BUNDLE_ID=com.example.runner
export WDA_BUNDLEID TEST_RUNNER_BUNDLE_ID
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "manual bundle ids are kept on tvOS" "--bundleid=com.example.wda --testrunnerbundleid=com.example.runner --xctestconfig=WebDriverAgentRunner_tvOS.xctest" "$(calls ios)"

section "Linux, invalid code signature"
scenario
HOST_OS=LINUX
FAKE_RUNWDA=signature
FAKE_PGREP=runwda
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "invalid code signature is reported" "WDA can't be launched: invalid code signature" "$OUT"
check "invalid code signature is not retried" "1" "$(count '^runwda' "$(calls ios)")"
check "invalid code signature exits with 0" "0" "$STATUS"
check_not_contains "invalid code signature ends the entrypoint before its holder checks WDA" "Wda status is BROKEN!" "$OUT"
check_not_contains "invalid code signature is not a recoverable break" "process broke" "$OUT"

section "Linux, WDA can't start: testmanagerd does not answer"
hangs="${WORK}/zebrunner/wda-hang-starts"
lastReboot="${WORK}/lockdown/reboot/00008030-TEST"
# reboots: the number of the reboots of the device in the last run
reboots() {
  count '^reboot --udid=00008030-TEST' "$(calls ios)"
}
# exists <file>: true when the file exists
exists() {
  [[ -e "$1" ]] && echo true || echo false
}
# hang_scenario: a device of a Linux host whose WDA hangs in testmanagerd, a reboot is allowed after 2 starts
hang_scenario() {
  scenario
  HOST_OS=LINUX
  FAKE_RUNWDA=hang
  rm -f "${WORK}/wda_ok"
  export ALLOW_REBOOT=true WDA_FAILURES_BEFORE_REBOOT=2 REBOOT_INTERVAL=21600
}

hang_scenario
run_entrypoint
check_contains "the hang is reported" "WDA can't start: testmanagerd of the device does not answer (e.g. 'loading Accessibility'" "$OUT"
check_contains "the start with the hang is counted" "(1/2 starts in a row)" "$OUT"
check "the count is kept over the restarts" "1" "$(cat "$hangs" 2> /dev/null)"
check "the first start with the hang restarts" "1" "$STATUS"
check "no reboot before WDA_FAILURES_BEFORE_REBOOT" "0" "$(reboots)"
rerun_entrypoint nowda
check "the device is rebooted after WDA_FAILURES_BEFORE_REBOOT starts" "1" "$(reboots)"
check_contains "the reboot is reported" "(2 starts in a row). Rebooting the device!" "$OUT"
check "the reboot restarts the container" "1" "$STATUS"
check "the time of the reboot is kept in the lockdown volume" "true" \
  "$([[ "$(cat "$lastReboot" 2> /dev/null)" =~ ^[0-9]+$ ]] && echo true || echo false)"
check "the reboot resets the count" "false" "$(exists "$hangs")"
# the containers of the rebooted device are created again: a new /tmp/zebrunner, the same lockdown volume
rm -f "${WORK}"/zebrunner/*
rerun_entrypoint nowda
rerun_entrypoint nowda
check_contains "a hang within REBOOT_INTERVAL after the reboot needs a person" "seconds after its reboot (one per REBOOT_INTERVAL 21600 seconds): the device needs a person. Exiting!" "$OUT"
check "a hang within REBOOT_INTERVAL after the reboot exits with 0" "0" "$STATUS"
check "no second reboot within REBOOT_INTERVAL" "0" "$(reboots)"

hang_scenario
mkdir -p "$(dirname "$lastReboot")" "$(dirname "$hangs")"
echo $(($(date +%s) - 30000)) > "$lastReboot"
echo 1 > "$hangs"
run_entrypoint
check "a reboot older than REBOOT_INTERVAL allows another one" "1" "$(reboots)"

section "Linux, WDA can't start: the reboot is confirmed"
# reboot_scenario: the hang reaches WDA_FAILURES_BEFORE_REBOOT in this start
reboot_scenario() {
  hang_scenario
  mkdir -p "$(dirname "$hangs")"
  echo 1 > "$hangs"
  export REBOOT_CONFIRM_TIMEOUT=6
}

reboot_scenario
run_entrypoint
check_contains "the reboot of a USB device is confirmed when it leaves usbmuxd" "The device is rebooting: it left usbmuxd 0 seconds after 'ios reboot'." "$OUT"
check "the boot time is read before the reboot" "1" "$(count '^ps --udid=00008030-TEST' "$(calls ios)")"

reboot_scenario
FAKE_REBOOT=once
run_entrypoint
check "'ios reboot' without a reboot is asked once more" "2" "$(reboots)"
check_contains "the first 'ios reboot' without a reboot is reported" "'ios reboot' answered, but the device did not reboot within 6 seconds: it is still in usbmuxd, it answers and its boot time is the same." "$OUT"
check_contains "the second attempt is reported" "Rebooting the device: 'ios reboot' (attempt 2/2)." "$OUT"
check_contains "the second 'ios reboot' is confirmed" "The device is rebooting: it left usbmuxd" "$OUT"
check "the reboot confirmed by the second attempt is recorded" "true" \
  "$([[ "$(cat "$lastReboot" 2> /dev/null)" =~ ^[0-9]+$ ]] && echo true || echo false)"
check "the reboot confirmed by the second attempt restarts the container" "1" "$STATUS"

reboot_scenario
FAKE_REBOOT=noop
run_entrypoint
check "a device that does not reboot gets 2 'ios reboot'" "2" "$(reboots)"
check "the device is polled within REBOOT_CONFIRM_TIMEOUT: 4 checks per attempt" "8" "$(count '^list' "$(calls ios)")"
check_contains "a device that does not reboot needs a person" "The device did not reboot on 'ios reboot' (2 attempts): the device needs a person, reboot it by hand. Exiting!" "$OUT"
check "a device that does not reboot exits with 0" "0" "$STATUS"
check "a reboot that did not happen is not recorded for REBOOT_INTERVAL" "false" "$(exists "$lastReboot")"
check "a reboot that did not happen resets the count" "false" "$(exists "$hangs")"
check_not_contains "a reboot that did not happen is not reported as a reboot" "The device is rebooting" "$OUT"
# the container is started again (e.g. by hand): the next hangs are not blocked by REBOOT_INTERVAL
FAKE_REBOOT=usb
rerun_entrypoint nowda
rerun_entrypoint nowda
check "the reboot is tried again after WDA_FAILURES_BEFORE_REBOOT starts" "1" "$(reboots)"
check_not_contains "a reboot that did not happen does not stop the next one" "the device needs a person" "$OUT"

reboot_scenario
DEVICE_CONNECTION=wireless
DEVICE_ADDRESS=192.168.50.20
FAKE_REBOOT=silent
run_entrypoint
check_contains "the reboot of a network device that stays in netmuxd is confirmed when it stops answering" "The device is rebooting: it stopped answering 2 seconds after 'ios reboot'." "$OUT"
check "the reboot of a network device is recorded" "true" "$(exists "$lastReboot")"
check "the reboot of a network device is confirmed by its first 'ios reboot'" "1" "$(reboots)"

reboot_scenario
FAKE_REBOOT=boot
run_entrypoint
check_contains "the reboot is confirmed by a new boot time (the earliest start of 'ios ps')" "The device is rebooting: its boot time changed from" "$OUT"
check "the reboot confirmed by the boot time is recorded" "true" "$(exists "$lastReboot")"

reboot_scenario
FAKE_REBOOT=boot
FAKE_PS=none
run_entrypoint
check "without the boot time a device that stays connected is not confirmed" "2" "$(reboots)"
check "without the boot time a device that stays connected exits with 0" "0" "$STATUS"

hang_scenario
ALLOW_REBOOT=false
mkdir -p "$(dirname "$hangs")"
echo 1 > "$hangs"
run_entrypoint
check "no reboot without ALLOW_REBOOT" "0" "$(reboots)"
check_contains "without ALLOW_REBOOT the reboot is recommended" "(2 starts in a row). Device reboot is recommended (ALLOW_REBOOT=true reboots it)!" "$OUT"
check_contains "without ALLOW_REBOOT the container restarts as before" "No response from WDA, or WDA is unhealthy. Restarting!" "$OUT"
check "without ALLOW_REBOOT the container exits with 1 as before" "1" "$STATUS"

hang_scenario
FAKE_IOS_VERSION=17.5
FAKE_PASSCODE=1
mkdir -p "$(dirname "$hangs")"
echo 1 > "$hangs"
run_entrypoint
check "iOS 17+ with a passcode is not rebooted without a backup of the pair record" "0" "$(reboots)"
check_contains "iOS 17+ with a passcode without a backup is reported" "its pair record has no backup, reboot it by hand!" "$OUT"

hang_scenario
FAKE_IOS_VERSION=17.5
FAKE_PASSCODE=1
mkdir -p "$(dirname "$hangs")" "${WORK}/lockdown/backup"
echo 1 > "$hangs"
echo record > "${WORK}/lockdown/00008030-TEST.plist"
echo record > "${WORK}/lockdown/backup/00008030-TEST.plist"
run_entrypoint
check "iOS 17+ with a passcode and a backup of the pair record is rebooted" "1" "$(reboots)"

hang_scenario
FAKE_IOS_VERSION=17.5
mkdir -p "$(dirname "$hangs")"
echo 1 > "$hangs"
run_entrypoint
check "iOS 17+ without a passcode is rebooted" "1" "$(reboots)"

hang_scenario
FAKE_PGREP=runwda
run_entrypoint
check "the failed runs of one start are one start" "1" "$(cat "$hangs" 2> /dev/null)"
check_contains "WDA that can't run restarts until the reboot" "Can't run WDA. Restarting!" "$OUT"
check "WDA that can't run exits with 1 until the reboot" "1" "$STATUS"
rerun_entrypoint nowda
check "WDA that can't run is rebooted after WDA_FAILURES_BEFORE_REBOOT starts" "1" "$(reboots)"

hang_scenario
FAKE_PGREP=runwda
ALLOW_REBOOT=false
run_entrypoint
check_contains "without ALLOW_REBOOT WDA that can't run stops as before" "Can't run WDA. Exiting!" "$OUT"
check "without ALLOW_REBOOT WDA that can't run exits with 0" "0" "$STATUS"

hang_scenario
FAKE_RUNWDA=nostart
run_entrypoint
check "another failure of WDA is not counted" "false" "$(exists "$hangs")"
check_not_contains "another failure of WDA is not a hang" "testmanagerd" "$OUT"

hang_scenario
FAKE_RUNWDA=ok
mkdir -p "$(dirname "$hangs")"
echo 1 > "$hangs"
run_entrypoint
check_contains "WDA starts" "Wda status is OK!" "$OUT"
check "a WDA that answers resets the count" "false" "$(exists "$hangs")"

for value in maybe 1; do
  scenario
  export ALLOW_REBOOT="$value"
  run_entrypoint
  check_contains "ALLOW_REBOOT='${value}' is reported" "ALLOW_REBOOT must be true or false, but it is '${value}'." "$OUT"
  check "ALLOW_REBOOT='${value}' exits with 0" "0" "$STATUS"
done
scenario
export ALLOW_REBOOT=TRUE
run_entrypoint
check_not_contains "ALLOW_REBOOT is case-insensitive" "ALLOW_REBOOT must be" "$OUT"
for var in WDA_FAILURES_BEFORE_REBOOT REBOOT_INTERVAL REBOOT_CONFIRM_TIMEOUT; do
  scenario
  export "${var}=abc"
  run_entrypoint
  check_contains "${var}='abc' is reported" "${var} must be a non-negative integer, but it is 'abc'." "$OUT"
done
scenario
export WDA_FAILURES_BEFORE_REBOOT=0
run_entrypoint
check_contains "WDA_FAILURES_BEFORE_REBOOT=0 is reported" "WDA_FAILURES_BEFORE_REBOOT must be 1 or more." "$OUT"
check "WDA_FAILURES_BEFORE_REBOOT=0 exits with 0" "0" "$STATUS"

section "Linux, iOS 17+: ncm and tunnel"
scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=17.5
run_entrypoint
check "iOS after 17.4.0 on Linux needs no ncm" "" "$(calls go-ncm)"
check_contains "tunnel is started for the device" "tunnel start --pair-record-path=/var/lib/lockdown --udid=00008030-TEST" "$(calls ios)"
check_contains "tunnel is reported" "Go-ios '/tunnels' endpoint is available:" "$OUT"
check_contains "the startup goes on after the tunnel" "Developer Image mounted successfully." "$OUT"
check_contains "iOS after 17.4.0 gets a userspace tunnel" "tunnel start --pair-record-path=/var/lib/lockdown --udid=00008030-TEST --userspace" "$(calls ios)"
check_contains "the tunnel is shared on the address of the container" "TCP-LISTEN:60106,bind=172.18.0.5,reuseaddr,fork|TCP:127.0.0.1:60106" "$(calls socat)"
check_contains "the shared tunnel is reported" "The tunnel is shared on 172.18.0.5:60106, its API on port 60105." "$OUT"
check_contains "the API of the tunnel listens on all the interfaces" "tunnel|0.0.0.0" "$(cat "${WORK}/agent.log" 2> /dev/null)"
check_contains "the go-ios commands find the shared tunnel" "apps|0.0.0.0" "$(cat "${WORK}/agent.log" 2> /dev/null)"

for version in 17.4 17.4.0 17.2.1; do
  scenario
  HOST_OS=LINUX
  FAKE_IOS_VERSION=$version
  run_entrypoint
  check_contains "iOS ${version} keeps the kernel tunnel" "tunnel start --pair-record-path=/var/lib/lockdown --udid=00008030-TEST" "$(calls ios)"
  check_not_contains "iOS ${version} has no userspace tunnel" "--userspace" "$(calls ios)"
  check_not_contains "iOS ${version} does not share the tunnel" "TCP-LISTEN:60106" "$(calls socat)"
  check "iOS ${version} keeps the API of the tunnel on localhost" "" "$(cat "${WORK}/agent.log" 2> /dev/null)"
  check "iOS ${version} on Linux starts ncm for the kernel tunnel" "--prometheusport=3030" "$(calls go-ncm)"
  check_contains "iOS ${version}: the ncm device is counted" "Found 1 device connected with ncm." "$OUT"
done

# an Apple TV has no USB configuration of NCM: tvOS after 17.4.0 starts without go-ncm
scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=18.2
FAKE_DEVICE_CLASS=AppleTV
run_entrypoint
check "Apple TV with tvOS after 17.4.0 on Linux needs no ncm" "" "$(calls go-ncm)"
check_contains "Apple TV with tvOS after 17.4.0 on Linux gets a userspace tunnel" "--userspace" "$(calls ios)"
check_contains "Apple TV with tvOS after 17.4.0 on Linux starts" "Developer Image mounted successfully." "$OUT"

for version in 17.4.1 18.7.10 26.0; do
  scenario
  HOST_OS=LINUX
  FAKE_IOS_VERSION=$version
  run_entrypoint
  check_contains "iOS ${version} gets a userspace tunnel" "--userspace" "$(calls ios)"
done

scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=18.7.10
FAKE_TUNNEL=noport
run_entrypoint
check_contains "a tunnel without its port restarts the container" "Can't share the tunnel (port '0', address '172.18.0.5'). Restarting!" "$OUT"
check "a tunnel without its port exits with 1" "1" "$STATUS"

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
check_contains "iOS 17.5 on macOS gets a userspace tunnel over the usbmuxd of the host" "tunnel start --pair-record-path=/var/lib/lockdown --udid=00008030-TEST --userspace" "$(calls ios)"
check_contains "the tunnel of macOS is shared too" "TCP-LISTEN:60106,bind=172.18.0.5,reuseaddr,fork|TCP:127.0.0.1:60106" "$(calls socat)"

scenario
FAKE_IOS_VERSION=17.2
run_entrypoint
check "iOS 17.2 on macOS has no ncm" "" "$(calls go-ncm)"
check_not_contains "iOS 17.2 on macOS has no tunnel" "tunnel start" "$(calls ios)"
check_contains "iOS 17.2 on macOS expects WDA started outside" "WDA is expected to be started outside the container." "$OUT"

scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=17.2
FAKE_NCM=down
run_entrypoint
check_contains "unavailable ncm metrics are reported" "Ncm '/metrics' endpoint is not available." "$OUT"
check_contains "unavailable ncm restarts the container" "Ncm can't connect with device. Restarting!" "$OUT"
check "unavailable ncm exits with 1" "1" "$STATUS"
check_not_contains "no tunnel without ncm" "tunnel start" "$(calls ios)"

scenario
HOST_OS=LINUX
FAKE_IOS_VERSION=17.2
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

section "macOS: WDA of the host or of the container"
scenario
run_entrypoint
check_contains "WDA started by the host is used" "WDA started outside the container is used" "$OUT"
check_not_contains "WDA of the host is not started again" "runwda" "$(calls ios)"

scenario
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "missing WDA is detected on macOS" "Running WDA not detected." "$OUT"
check "WDA is started by the container on macOS" "1" "$(count '^runwda' "$(calls ios)")"
check_contains "ports are forwarded before WDA starts on macOS" "forward 8100 8100" "$(calls ios)"
check_contains "WDA of the container becomes healthy on macOS" "Wda status is OK!" "$OUT"

section "connection validation"
for value in bluetooth "usb wireless" emulator simulator; do
  scenario
  DEVICE_CONNECTION=$value
  run_entrypoint
  check_contains "DEVICE_CONNECTION='${value}' is reported" "DEVICE_CONNECTION must be usb, wireless, ios-sim or proxy, but it is '${value}'." "$OUT"
  check "DEVICE_CONNECTION='${value}' exits with 0" "0" "$STATUS"
done

for value in USB Wireless IOS-SIM proxy; do
  scenario
  DEVICE_CONNECTION=$value
  DEVICE_ADDRESS=192.168.1.10
  FAKE_PORT_BUSY=1
  run_entrypoint
  check_not_contains "DEVICE_CONNECTION='${value}' is valid" "DEVICE_CONNECTION must be" "$OUT"
done

scenario
DEVICE_CONNECTION=wireless
HOST_OS=LINUX
run_entrypoint
check_contains "wireless device needs its address" "DEVICE_ADDRESS is required for the 'wireless' connection." "$OUT"
check "wireless device without address exits with 0" "0" "$STATUS"

scenario
DEVICE_CONNECTION=wireless
USBMUXD_SOCKET_ADDRESS=host.docker.internal:2222
FAKE_PORT_BUSY=1
run_entrypoint
check_not_contains "wireless device of an external usbmuxd needs no address" "DEVICE_ADDRESS is required" "$OUT"

scenario
DEVICE_CONNECTION=proxy
run_entrypoint
check_contains "proxy needs the address of WDA" "DEVICE_ADDRESS is required for the 'proxy' connection." "$OUT"

sim_scenario
HOST_OS=LINUX
run_entrypoint
check_contains "simulator needs macOS" "Simulators run on a macOS host only (HOST_OS=DARWIN), but HOST_OS is 'LINUX'." "$OUT"
check "simulator on Linux exits with 0" "0" "$STATUS"

sim_scenario
HOST_SSH_USER=''
run_entrypoint
check_contains "simulator needs the ssh user of the host" "HOST_SSH_USER is required for the ios-sim connection." "$OUT"

for var in HOST_SSH_PORT HOST_SSH_PROXY_PORT DEVICE_WDA_PORT DEVICE_MJPEG_PORT; do
  sim_scenario
  export "${var}=abc"
  run_entrypoint
  check_contains "${var}='abc' is reported" "${var} must be a non-negative integer, but it is 'abc'." "$OUT"
done

for value in "x' /Users/builder '" 00008030-001A2B3C4D5E6F70 "6A1C8E2B-4F3D-4E5A-9B7C-1D2E3F4A5B6C; true"; do
  sim_scenario
  DEVICE_UDID="$value"
  run_entrypoint
  check_contains "simulator udid '${value}' is reported" "DEVICE_UDID of a simulator must be a UUID, but it is '${value}'." "$OUT"
  check "simulator udid '${value}' exits with 0" "0" "$STATUS"
  check "simulator udid '${value}' is not passed to the host" "" "$(calls ssh)"
done

for value in "" "com.facebook.WebDriverAgentRunner.xctrunner' 'x" "a b"; do
  sim_scenario
  WDA_BUNDLEID="$value"
  run_entrypoint
  check_contains "simulator WDA_BUNDLEID '${value}' is reported" "WDA_BUNDLEID must be a bundle identifier (letters, digits, '.' and '-'), but it is '${value}'." "$OUT"
  check "simulator WDA_BUNDLEID '${value}' is not passed to the host" "" "$(calls ssh)"
done

scenario
DEVICE_UDID="x' y"
WDA_BUNDLEID="a b"
FAKE_PORT_BUSY=1
run_entrypoint
check_not_contains "the udid of a device is not a UUID" "must be a UUID" "$OUT"
check_not_contains "the bundle id is validated for the simulators only" "must be a bundle identifier" "$OUT"

scenario
HOST_SSH_PORT=abc
FAKE_PORT_BUSY=1
run_entrypoint
check_not_contains "ssh settings are not validated without simulators" "HOST_SSH_PORT must be" "$OUT"

section "wireless: netmuxd on Linux"
scenario
HOST_OS=LINUX
DEVICE_CONNECTION=wireless
DEVICE_ADDRESS=192.168.50.20
FAKE_IOS_VERSION=18.7.10
rm "${WORK}/wda_ok"
run_entrypoint
check "netmuxd serves the network device" "--disable-usb|--disable-mdns|--plist-storage|/var/lib/lockdown" "$(calls netmuxd)"
check "usbmuxd is not started for a wireless device" "" "$(calls usbmuxd)"
check "the device is added to netmuxd by its address" "add-network-device|00008030-TEST|192.168.50.20" "$(calls mcloud-ios)"
check_contains "the socket of netmuxd is forwarded to the port" "TCP-LISTEN:2222,reuseaddr,fork|UNIX-CONNECT:/var/run/usbmuxd" "$(calls socat)"
check_contains "missing pair record is reported" "No pair record /var/lib/lockdown/00008030-TEST.plist" "$OUT"
check "wireless device has no ncm" "" "$(calls go-ncm)"
check_contains "wireless device gets a userspace tunnel" "tunnel start --pair-record-path=/var/lib/lockdown --udid=00008030-TEST --userspace" "$(calls ios)"
check_contains "WDA of the wireless device is started" "runwda --bundleid=com.facebook.WebDriverAgentRunner.xctrunner" "$(calls ios)"
check_not_contains "WDA of the wireless device listens on the network" "USE_IP" "$(calls ios)"
check_contains "the address of the wireless WDA is logged" "WebDriverAgent listens on all the interfaces of the device: the 'wireless' connection reaches it over the network (WDA_BIND_ADDRESS=auto)." "$OUT"
check_contains "WDA of the wireless device becomes healthy" "Wda status is OK!" "$OUT"

scenario
DEVICE_CONNECTION=wireless
USBMUXD_SOCKET_ADDRESS=host.docker.internal:2222
export USBMUXD_SOCKET_ADDRESS
run_entrypoint
check "netmuxd is not started for an external usbmuxd" "" "$(calls netmuxd)"
check "no device is added to an external usbmuxd" "" "$(calls mcloud-ios)"
check_contains "the external usbmuxd is forwarded to the port" "TCP-LISTEN:2222,reuseaddr,fork|TCP:host.docker.internal:2222" "$(calls socat)"

section "proxy: WDA of another tool"
scenario
DEVICE_CONNECTION=proxy
DEVICE_ADDRESS=192.168.50.30
DEVICE_WDA_PORT=18100
DEVICE_MJPEG_PORT=18101
export DEVICE_WDA_PORT DEVICE_MJPEG_PORT
run_entrypoint
check_contains "WDA port is relayed" "TCP-LISTEN:8100,reuseaddr,fork|TCP:192.168.50.30:18100" "$(calls socat)"
check_contains "MJPEG port is relayed" "TCP-LISTEN:8101,reuseaddr,fork|TCP:192.168.50.30:18101" "$(calls socat)"
check "no usbmuxd for the proxy" "" "$(calls usbmuxd)$(calls netmuxd)"
check "no go-ios for the proxy" "" "$(calls ios)"
check_contains "relayed WDA becomes healthy" "Wda status is OK!" "$OUT"
check_contains "lost relayed WDA is reported" "Wda status is BROKEN!" "$OUT"
check "lost relayed WDA exits with 1" "1" "$STATUS"

scenario
DEVICE_CONNECTION=proxy
DEVICE_ADDRESS=192.168.50.30
run_entrypoint
check_contains "the device ports are WDA_PORT and MJPEG_PORT by default" "TCP:192.168.50.30:8100" "$(calls socat)"

scenario
DEVICE_CONNECTION=proxy
DEVICE_ADDRESS=192.168.50.30
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "unreachable relayed WDA restarts the container" "No response from WDA, or WDA is unhealthy. Restarting!" "$OUT"
check "unreachable relayed WDA exits with 1" "1" "$STATUS"

scenario
DEVICE_CONNECTION=proxy
DEVICE_ADDRESS=192.168.50.30
FAKE_RELAY=stop
run_entrypoint
check_contains "stopped relay is reported" "Relay of port 8100 to 192.168.50.30:8100 stopped. Restarting!" "$OUT"
check "stopped relay exits with 1" "1" "$STATUS"
check_not_contains "stopped relay ends the entrypoint before its holder checks WDA" "Wda status is BROKEN!" "$OUT"

section "simulator: the macOS host over ssh"
sim_scenario
DEVICE_WDA_PORT=8110
DEVICE_MJPEG_PORT=8111
export DEVICE_WDA_PORT DEVICE_MJPEG_PORT
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "the host is reached with the key of the container" "-i ${WORK}/zebrunner/ssh_key -p 22" "$(calls ssh)"
check "the copied key is private" "600" "$(stat -c %a "${WORK}/zebrunner/ssh_key" 2> /dev/null || stat -f %Lp "${WORK}/zebrunner/ssh_key")"
check_contains "the host is reached as the user" "builder@host.docker.internal" "$(calls ssh)"
check_contains "the simulator is booted" "xcrun simctl bootstatus 6A1C8E2B-4F3D-4E5A-9B7C-1D2E3F4A5B6C -b" "$(calls ssh)"
check_contains "the type of the simulator is detected" "device type: 'Phone'" "$OUT"
check_contains "installed WDA is used without WDA_FILE" "is already installed, there is no" "$OUT"
check_contains "WDA is launched with its ports" "SIMCTL_CHILD_USE_PORT=8110 SIMCTL_CHILD_MJPEG_SERVER_PORT=8111" "$(calls ssh)"
check_contains "WDA of the simulator listens on the loopback of the host" "SIMCTL_CHILD_MJPEG_SERVER_PORT=8111 SIMCTL_CHILD_USE_IP=127.0.0.1 SIMCTL_CHILD_WDA_PRODUCT_BUNDLE_IDENTIFIER=" "$(calls ssh)"
check_contains "WDA is launched by its bundle" "xcrun simctl launch --terminate-running-process '6A1C8E2B-4F3D-4E5A-9B7C-1D2E3F4A5B6C' 'com.facebook.WebDriverAgentRunner.xctrunner'" "$(calls ssh)"
check_contains "WDA port of the simulator is relayed" "TCP-LISTEN:8100,reuseaddr,fork|TCP:host.docker.internal:8110" "$(calls socat)"
check_contains "MJPEG port of the simulator is relayed" "TCP-LISTEN:8101,reuseaddr,fork|TCP:host.docker.internal:8111" "$(calls socat)"
check_contains "ssh of the host is relayed for appium" "TCP-LISTEN:22,reuseaddr,fork|TCP:host.docker.internal:22" "$(calls socat)"
check "no usbmuxd for a simulator" "" "$(calls usbmuxd)$(calls netmuxd)"
check "no go-ios for a simulator" "" "$(calls ios)"
check_contains "WDA of the simulator becomes healthy" "Wda status is OK!" "$OUT"

sim_scenario
HOST_SSH_HOST=mac-mini.local
rm "${WORK}/wda_ok"
run_entrypoint
check_not_contains "WDA of a simulator of a remote host listens on the network" "USE_IP" "$(calls ssh)"
check_contains "the address of the WDA of a remote host is logged" "WebDriverAgent listens on all the interfaces of the macOS host: HOST_SSH_HOST 'mac-mini.local' reaches it over the network (WDA_BIND_ADDRESS=auto)." "$OUT"
check_contains "WDA of a simulator of a remote host becomes healthy" "Wda status is OK!" "$OUT"

sim_scenario
WDA_BIND_ADDRESS=all
export WDA_BIND_ADDRESS
rm "${WORK}/wda_ok"
run_entrypoint
check_not_contains "WDA_BIND_ADDRESS=all: WDA of the simulator listens on every interface" "USE_IP" "$(calls ssh)"

sim_scenario
FAKE_SIM_RUNTIME=com.apple.CoreSimulator.SimRuntime.tvOS-18-5
FAKE_SIM_TYPE=com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K
run_entrypoint
check_contains "tvOS simulator is detected" "device type: 'tvOS'" "$OUT"

sim_scenario
FAKE_SIM_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M3
run_entrypoint
check_contains "iPad simulator is detected" "device type: 'Tablet'" "$OUT"

sim_scenario
FAKE_SIM_UDID=OTHER
run_entrypoint
check_contains "unknown simulator is reported" "Simulator '6A1C8E2B-4F3D-4E5A-9B7C-1D2E3F4A5B6C' is not found" "$OUT"
check "unknown simulator exits with 0" "0" "$STATUS"

sim_scenario
FAKE_SSH=denied
run_entrypoint
check_contains "refused key is reported" "The macOS host refuses the ssh key" "$OUT"
check "refused key exits with 0" "0" "$STATUS"
check "refused key is not retried" "1" "$(count 'true$' "$(calls ssh)")"

sim_scenario
FAKE_SSH=down
run_entrypoint
check_contains "unreachable host restarts the container" "is not reachable over ssh. Restarting!" "$OUT"
check "unreachable host is retried 10 times" "10" "$(count 'true$' "$(calls ssh)")"
check "unreachable host exits with 1" "1" "$STATUS"

sim_scenario
rm -f "${WORK}/id_ed25519"
run_entrypoint
check_contains "missing ssh key is reported" "The ssh key '${WORK}/id_ed25519' of the macOS host is not found. Exiting!" "$OUT"
check "missing ssh key exits with 0" "0" "$STATUS"

sim_scenario
FAKE_SIM_BOOT=fail
run_entrypoint
check_contains "failed boot restarts the container" "The simulator is not booted" "$OUT"
check "failed boot exits with 1" "1" "$STATUS"

sim_scenario
FAKE_WDA_INSTALLED=0
run_entrypoint
check_contains "simulator build of WDA is required" "(a simulator build of WDA: a .app folder or its .zip) does not exist. Exiting!" "$OUT"
check "missing simulator build exits with 0" "0" "$STATUS"

sim_scenario
WDA_FILE="${WORK}/WebDriverAgentRunner-Runner.app"
export WDA_FILE
mkdir -p "$WDA_FILE"
run_entrypoint
check_contains "WDA is copied to the host" "tar -xf - -C '/tmp/zebrunner-wda-6A1C8E2B-4F3D-4E5A-9B7C-1D2E3F4A5B6C'" "$(calls ssh)"
check_contains "WDA is installed on the simulator" "xcrun simctl install '6A1C8E2B-4F3D-4E5A-9B7C-1D2E3F4A5B6C'" "$(calls ssh)"
check_contains "the copy of WDA is removed" "rm -rf '/tmp/zebrunner-wda-6A1C8E2B-4F3D-4E5A-9B7C-1D2E3F4A5B6C'" "$(calls ssh)"
check_contains "installed WDA is launched" "simctl launch" "$(calls ssh)"
check_not_contains "WDA_FILE replaces the installed WDA" "get_app_container" "$(calls ssh)"
rm -rf "$WDA_FILE"

sim_scenario
FAKE_WDA_INSTALLED=0
FAKE_INSTALL=fail
WDA_FILE="${WORK}/wda.zip"
export WDA_FILE
touch "$WDA_FILE"
run_entrypoint
check_contains "failed install on the simulator is reported" "Error while installing WDA_FILE" "$OUT"
check "failed install on the simulator exits with 0" "0" "$STATUS"

sim_scenario
FAKE_SIM_LAUNCH=fail
rm "${WORK}/wda_ok"
run_entrypoint
check_contains "failed launch of WDA restarts the container" "WDA can't be launched: launch failed. Restarting!" "$OUT"
check "failed launch of WDA exits with 1" "1" "$STATUS"

section "stop"
for connection in usb proxy; do
  scenario
  HOST_OS=LINUX
  DEVICE_CONNECTION="$connection"
  DEVICE_ADDRESS=192.168.0.20
  FAKE_STOP=1
  rm -f "${WORK}/socat.pids"
  started="$SECONDS"
  run_entrypoint
  check "${connection}: SIGTERM ends the entrypoint with 0" "0" "$STATUS"
  check "${connection}: SIGTERM ends the pause of the holder at once" "true" \
    "$([[ $((SECONDS - started)) -lt 10 ]] && echo true || echo false)"
  check_contains "${connection}: the stop is logged" "Stopped. Exiting!" "$OUT"
  running=""
  while read -r pid; do
    kill -0 "$pid" 2> /dev/null && running+="${pid} "
  done < "${WORK}/socat.pids"
  check "${connection}: the relays are stopped" "" "$running"
done

finish
