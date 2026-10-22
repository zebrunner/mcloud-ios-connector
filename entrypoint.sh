#!/bin/bash

# shellcheck source=util/debug.sh
. /opt/zebrunner/util/debug.sh
# shellcheck source=util/logger.sh
. /opt/zebrunner/util/logger.sh

logger "INFO" "\n\n\n\t\tMCLOUD-IOS-CONNECTOR\n\n"

#### Preparation steps
# If HOST_OS is null or unset use default value (LINUX or DARWIN, mcloud-agent passes it; MACOS is the same as DARWIN)
HOST_OS="${HOST_OS:-"LINUX"}"
# How the device is reached: usb (default), wireless (lockdown over Wi-Fi), simulator (macOS host over ssh) or
# proxy (WebDriverAgent published by another tool)
DEVICE_CONNECTION="${DEVICE_CONNECTION:-usb}"
DEVICE_CONNECTION="${DEVICE_CONNECTION,,}"
# The ports of WebDriverAgent on the side of the device: a simulator shares the network of the macOS host, so they
# are unique for every simulator
DEVICE_WDA_PORT="${DEVICE_WDA_PORT:-$WDA_PORT}"
DEVICE_MJPEG_PORT="${DEVICE_MJPEG_PORT:-$MJPEG_PORT}"

#### Validate configuration
# A wrong configuration can't be fixed by a restart, so exit with 0 like the other unrecoverable errors
isConfigValid=1
if [[ -z "${DEVICE_UDID}" ]]; then
  logger "ERROR" "DEVICE_UDID is required but empty or unset."
  isConfigValid=0
fi
if [[ ! "${HOST_OS^^}" =~ ^(LINUX|DARWIN|MACOS)$ ]]; then
  logger "ERROR" "HOST_OS must be LINUX, DARWIN or MACOS, but it is '$HOST_OS'."
  isConfigValid=0
fi
if [[ ! "$DEVICE_CONNECTION" =~ ^(usb|wireless|simulator|proxy)$ ]]; then
  logger "ERROR" "DEVICE_CONNECTION must be usb, wireless, simulator or proxy, but it is '$DEVICE_CONNECTION'."
  isConfigValid=0
fi
# A wireless device is added to the netmuxd of the container by its address, unless an external usbmuxd (the one
# of the macOS host) already knows it; the WebDriverAgent of the proxy connection is published on DEVICE_ADDRESS
if [[ "$DEVICE_CONNECTION" == "proxy" || ("$DEVICE_CONNECTION" == "wireless" && -z "$USBMUXD_SOCKET_ADDRESS") ]] &&
  [[ -z "$DEVICE_ADDRESS" ]]; then
  logger "ERROR" "DEVICE_ADDRESS is required for the '$DEVICE_CONNECTION' connection."
  isConfigValid=0
fi
if [[ "$DEVICE_CONNECTION" == "simulator" ]]; then
  if [[ ! "${HOST_OS^^}" =~ ^(DARWIN|MACOS)$ ]]; then
    logger "ERROR" "Simulators run on a macOS host only (HOST_OS=DARWIN), but HOST_OS is '$HOST_OS'."
    isConfigValid=0
  fi
  if [[ -z "$HOST_SSH_USER" ]]; then
    logger "ERROR" "HOST_SSH_USER is required for the simulator connection."
    isConfigValid=0
  fi
fi
numericVars=(POLLING_SEC USBMUXD_PORT WDA_PORT MJPEG_PORT WDA_WAIT_TIMEOUT DEVICE_UNAVAILABLE_TIMEOUT DEVICE_WDA_PORT
  DEVICE_MJPEG_PORT)
if [[ "$DEVICE_CONNECTION" == "simulator" ]]; then
  numericVars+=(HOST_SSH_PORT HOST_SSH_PROXY_PORT)
fi
for var in "${numericVars[@]}"; do
  if [[ ! "${!var}" =~ ^[0-9]+$ ]]; then
    logger "ERROR" "$var must be a non-negative integer, but it is '${!var}'."
    isConfigValid=0
  fi
done
if [[ $isConfigValid -eq 0 ]]; then
  logger "ERROR" "Invalid configuration. Exiting!"
  exit 0
fi
logger "Connection of the device: '$DEVICE_CONNECTION'."

#### Background processes
# The relays, runWda and forwardPort run in the background, so their exit ends only their subshell. A background
# failure is passed to the entrypoint with this file, the entrypoint exits with its content (see exitOnBackgroundFailure)
backgroundExitFile="/tmp/log/background.exit"
rm -f "$backgroundExitFile"

# exitInBackground <code>: ends the background subshell and asks the entrypoint to exit with the code
exitInBackground() {
  echo "$1" > "$backgroundExitFile"
  exit "$1"
}

exitOnBackgroundFailure() {
  if [[ -s "$backgroundExitFile" ]]; then
    exit "$(cat "$backgroundExitFile")"
  fi
}

# isWdaUp: WebDriverAgent answers its status on WDA_HOST:WDA_PORT (GET: the newer WDA builds answer 404 to HEAD)
isWdaUp() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${WDA_HOST}:${WDA_PORT}/status" | grep -q '^200$'
}

# relayPort <port> <host> <target port>: forwards the port of the container to the target, in the background;
# socat ends only when it can't listen on the port, a restart is asked then
relayPort() {
  logger "Relaying port $1 to $2:$3."
  socat TCP-LISTEN:"$1",reuseaddr,fork TCP:"$2":"$3"
  logger "ERROR" "Relay of port $1 to $2:$3 stopped. Restarting!"
  exitInBackground 1
}

# waitForWda: waits WDA_WAIT_TIMEOUT seconds for WebDriverAgent, a restart is asked when it does not answer
waitForWda() {
  local startTime
  startTime=$(date +%s)
  while [[ $((startTime + WDA_WAIT_TIMEOUT)) -gt "$(date +%s)" ]]; do
    exitOnBackgroundFailure
    if isWdaUp; then
      logger "Wda status is OK!"
      return 0
    fi
    logger "WARN" "Bad or no response from 'http://${WDA_HOST}:${WDA_PORT}/status'. One more attempt..."
    sleep 2
  done
  logger "ERROR" "No response from WDA, or WDA is unhealthy. Restarting!"
  exit 1
}

# holdWda: the entrypoint holder, WebDriverAgent is checked every 33 seconds, a restart is asked when it does not
# answer 4 times in a row
holdWda() {
  declare -i wdaCount=0
  while :; do
    sleep 33
    exitOnBackgroundFailure
    if isWdaUp; then
      logger "Wda status is OK!"
      wdaCount=0
    else
      logger "Wda status is BROKEN!"
      if [[ $wdaCount -ge 3 ]]; then
        exit 1
      else
        wdaCount+=1
      fi
    fi
  done
}

#### Proxy connection
# WebDriverAgent of the device is started and published by another tool (e.g. an Apple TV tunnel of the host): the
# connector only relays its ports, so the other containers of the device reach it as usual
if [[ "$DEVICE_CONNECTION" == "proxy" ]]; then
  relayPort "$WDA_PORT" "$DEVICE_ADDRESS" "$DEVICE_WDA_PORT" &
  relayPort "$MJPEG_PORT" "$DEVICE_ADDRESS" "$DEVICE_MJPEG_PORT" &
  waitForWda
  holdWda
fi

#### Simulator connection
# The simulator runs on the macOS host: the connector boots it, installs and launches WebDriverAgent over ssh and relays
# the ports of WebDriverAgent and ssh, so the other containers of the device reach it as usual
if [[ "$DEVICE_CONNECTION" == "simulator" ]]; then
  # ssh refuses a private key readable by others, the mounted one is copied
  sshKey="/tmp/zebrunner/ssh_key"
  mkdir -p /tmp/zebrunner
  if ! cp "$HOST_SSH_KEY" "$sshKey" 2> /dev/null; then
    logger "ERROR" "The ssh key '$HOST_SSH_KEY' of the macOS host is not found. Exiting!"
    exit 0
  fi
  chmod 600 "$sshKey"

  # hostSsh <command>: runs the command on the macOS host
  hostSsh() {
    ssh -i "$sshKey" -p "$HOST_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/tmp/zebrunner/known_hosts -o ConnectTimeout=10 -o ServerAliveInterval=15 \
      "${HOST_SSH_USER}@${HOST_SSH_HOST}" "$@"
  }

  declare -i index=0
  isHostConnected=0
  while [[ $index -lt 10 ]]; do
    if sshOutput=$(hostSsh true 2>&1); then
      isHostConnected=1
      break
    fi
    if [[ "$sshOutput" == *"Permission denied"* ]]; then
      logger "ERROR" "The macOS host refuses the ssh key of ${HOST_SSH_USER}@${HOST_SSH_HOST}: ${sshOutput}"
      logger "ERROR" "Add the public key to ~/.ssh/authorized_keys of the user. Exiting!"
      exit 0
    fi
    logger "WARN" "The macOS host is not reachable over ssh: ${sshOutput}. One more attempt..."
    sleep "${POLLING_SEC}"
    index+=1
  done
  if [[ $isHostConnected -eq 0 ]]; then
    logger "ERROR" "The macOS host ${HOST_SSH_HOST}:${HOST_SSH_PORT} is not reachable over ssh. Restarting!"
    exit 1
  fi
  logger "The macOS host ${HOST_SSH_USER}@${HOST_SSH_HOST} is reachable over ssh."

  # the simulator, its runtime and type
  simulator=$(hostSsh xcrun simctl list devices --json 2> /dev/null | jq -c --arg udid "$DEVICE_UDID" \
    '[.devices | to_entries[] | .key as $runtime | .value[] | select(.udid == $udid) | . + {runtime: $runtime}] | first // empty')
  if [[ -z "$simulator" ]]; then
    logger "ERROR" "Simulator '$DEVICE_UDID' is not found by 'xcrun simctl list devices' on the macOS host. Exiting!"
    exit 0
  fi
  logger "Simulator: $simulator"
  simulatorRuntime=$(echo "$simulator" | jq -r '.runtime')
  case "$simulatorRuntime $(echo "$simulator" | jq -r '.deviceTypeIdentifier')" in
  *tvOS*) deviceType="tvOS" ;;
  *iPad*) deviceType="Tablet" ;;
  *) deviceType="Phone" ;;
  esac
  logger "Detected simulator runtime: '$simulatorRuntime', device type: '$deviceType'"

  logger "Booting the simulator."
  if ! bootOutput=$(hostSsh xcrun simctl bootstatus "$DEVICE_UDID" -b 2>&1); then
    logger "ERROR" "The simulator is not booted: ${bootOutput}. Restarting!"
    exit 1
  fi
  logger "The simulator is booted."

  # WDA_FILE is installed on every start: the installation takes seconds on a simulator and replaces a WDA that can't
  # be launched without xcodebuild (e.g. the one of an earlier xcodebuild session); without it the installed one is used
  if [[ ! -e "$WDA_FILE" ]] && hostSsh xcrun simctl get_app_container "$DEVICE_UDID" "$WDA_BUNDLEID" > /dev/null 2>&1; then
    logger "'$WDA_BUNDLEID' app is already installed, there is no '$WDA_FILE' to replace it"
  else
    if [[ ! -e "$WDA_FILE" ]]; then
      logger "ERROR" "'$WDA_FILE' (a simulator build of WDA: a .app folder or its .zip) does not exist. Exiting!"
      exit 0
    fi
    # the app is copied to the host and installed from there, a .zip is extracted first
    remoteDir="/tmp/zebrunner-wda-${DEVICE_UDID}"
    logger "Installing WDA application on the simulator:"
    if ! tar -C "$(dirname "$WDA_FILE")" -cf - "$(basename "$WDA_FILE")" |
      hostSsh "rm -rf '$remoteDir' && mkdir -p '$remoteDir' && tar -xf - -C '$remoteDir'"; then
      logger "ERROR" "Can't copy '$WDA_FILE' to the macOS host. Restarting!"
      exit 1
    fi
    # the remote commands are expanded by the shell of the host
    # shellcheck disable=SC2016
    wdaInstall=$(hostSsh "cd '$remoteDir' && for f in *.zip; do test -f \"\$f\" && ditto -x -k \"\$f\" .; done; " \
      "app=\$(find . -maxdepth 3 -type d -name '*.app' | head -1); test -n \"\$app\" || { echo 'no .app found'; exit 1; }; " \
      "xcrun simctl install '$DEVICE_UDID' \"\$app\"" 2>&1)
    wdaInstallStatus=$?
    hostSsh "rm -rf '$remoteDir'" > /dev/null 2>&1
    if [[ $wdaInstallStatus -ne 0 ]]; then
      logger "ERROR" "Error while installing WDA_FILE: '$WDA_FILE': ${wdaInstall}. Exiting!"
      exit 0
    fi
  fi

  logger "Starting WebDriverAgent application on port '$DEVICE_WDA_PORT' of the macOS host."
  if ! wdaLaunch=$(hostSsh "SIMCTL_CHILD_USE_PORT=$DEVICE_WDA_PORT SIMCTL_CHILD_MJPEG_SERVER_PORT=$DEVICE_MJPEG_PORT" \
    "SIMCTL_CHILD_WDA_PRODUCT_BUNDLE_IDENTIFIER='$WDA_BUNDLEID' SIMCTL_CHILD_UITEST_DISABLE_ANIMATIONS=YES" \
    "xcrun simctl launch --terminate-running-process '$DEVICE_UDID' '$WDA_BUNDLEID'" 2>&1); then
    logger "ERROR" "WDA can't be launched: ${wdaLaunch}. Restarting!"
    exit 1
  fi
  logger "WDA is launched: ${wdaLaunch}"

  relayPort "$WDA_PORT" "$HOST_SSH_HOST" "$DEVICE_WDA_PORT" &
  relayPort "$MJPEG_PORT" "$HOST_SSH_HOST" "$DEVICE_MJPEG_PORT" &
  # the appium container runs xcrun of the host over ssh through the connector
  relayPort "$HOST_SSH_PROXY_PORT" "$HOST_SSH_HOST" "$HOST_SSH_PORT" &
  waitForWda
  holdWda
fi

#### Establish and check usbmuxd connection
# Check if $USBMUXD_PORT port is free
declare -i index=0
isLocalPortFree=0
# TODO: adjust timeout based on real usage
while [[ $index -lt 10 ]]; do
  # If we can connect to the port, then someone is already waiting for a connection on this port
  if nc -z 127.0.0.1 "$USBMUXD_PORT"; then
    logger "ERROR" "127.0.0.1 $USBMUXD_PORT port is busy. One more attempt..."
    index+=1
    sleep 1
  else
    isLocalPortFree=1
    break
  fi
done
index=0

if [[ $isLocalPortFree -eq 1 ]]; then
  logger "127.0.0.1 $USBMUXD_PORT port is free."
else
  logger "ERROR" "127.0.0.1 $USBMUXD_PORT port is busy. Exiting!"
  exit 0
fi

# Check if selected usbmuxd socket available
declare -i index=0
isUsbmuxdConnected=0
if [[ -z $USBMUXD_SOCKET_ADDRESS ]]; then
  if [[ "$DEVICE_CONNECTION" == "wireless" ]]; then
    # netmuxd serves the usbmuxd protocol for a device of the network: no mDNS (the docker network does not pass it),
    # the device is added by its address and found by its pair record in /var/lib/lockdown
    logger "Start containerized netmuxd service/process for the network device."
    RUST_LOG="${RUST_LOG:-info}" netmuxd --disable-usb --disable-mdns --plist-storage /var/lib/lockdown &
  else
    logger "Start containerized usbmuxd service/process."
    usbmuxd -f &
  fi
  # Check if '/var/run/usbmuxd' exists
  while [[ $index -lt 10 ]]; do
    if ! socat /dev/null UNIX-CONNECT:/var/run/usbmuxd; then
      logger "ERROR" "Can't connect to '/var/run/usbmuxd'. One more attempt..."
      index+=1
      sleep 1
    else
      isUsbmuxdConnected=1
      socat TCP-LISTEN:"$USBMUXD_PORT",reuseaddr,fork UNIX-CONNECT:/var/run/usbmuxd &
      break
    fi
  done
  index=0
  if [[ $isUsbmuxdConnected -eq 1 && "$DEVICE_CONNECTION" == "wireless" ]]; then
    logger "Adding the network device '$DEVICE_UDID' at '$DEVICE_ADDRESS' to netmuxd."
    if [[ ! -f "/var/lib/lockdown/${DEVICE_UDID}.plist" ]]; then
      logger "WARN" "No pair record /var/lib/lockdown/${DEVICE_UDID}.plist: connect the device over USB once to pair it."
    fi
    mcloud-ios add-network-device "$DEVICE_UDID" "$DEVICE_ADDRESS" 2>&1 || logger "WARN" "netmuxd did not add the device."
  fi
else
  # rm /var/run/usbmuxd in advance to be able to start socat and join it to $USBMUXD_SOCKET_ADDRESS
  # rm -f /var/run/usbmuxd
  # socat UNIX-LISTEN:/var/run/usbmuxd,fork,reuseaddr,mode=777 TCP:"$USBMUXD_SOCKET_ADDRESS" &

  # Check if 'USBMUXD_SOCKET_ADDRESS' exists
  while [[ $index -lt 10 ]]; do
    if ! socat /dev/null TCP:"$USBMUXD_SOCKET_ADDRESS"; then
      logger "ERROR" "Can't connect to USBMUXD_SOCKET_ADDRESS: '$USBMUXD_SOCKET_ADDRESS'. One more attempt..."
      index+=1
      sleep 1
    else
      isUsbmuxdConnected=1
      socat TCP-LISTEN:"$USBMUXD_PORT",reuseaddr,fork TCP:"$USBMUXD_SOCKET_ADDRESS" &
      break
    fi
  done
  index=0
fi

if [[ $isUsbmuxdConnected -eq 1 ]]; then
  logger "Usbmuxd socket is available."
else
  logger "ERROR" "Usbmuxd socket is not available. Exiting!"
  exit 0
fi

# Check if 127.0.0.1 $USBMUXD_PORT port is accessible now
declare -i index=0
isPortAccessible=0
while [[ $index -lt 10 ]]; do
  if ! nc -z 127.0.0.1 "$USBMUXD_PORT"; then
    logger "ERROR" "Usbmuxd forwarding is not established. One more attempt..."
    index+=1
    sleep 1
  else
    isPortAccessible=1
    break
  fi
done
index=0

if [[ $isPortAccessible -eq 1 ]]; then
  logger "Usbmuxd forwarding established."
else
  logger "ERROR" "Usbmuxd forwarding is not established. Exiting!"
  exit 0
fi

#### Check device connection
# The container filesystem survives the restarts of the container, so the file tells for how long the device
# has been unavailable (e.g. unpaired) over the restarts. After DEVICE_UNAVAILABLE_TIMEOUT seconds the entrypoint
# exits with 0 to stop the restarts, 0 means restart forever.
deviceUnavailableFile="/tmp/zebrunner/device-unavailable-since"
declare -i index=0
isAvailable=0
while [[ $index -lt 10 ]]; do
  if deviceInfo=$(ios info --udid="$DEVICE_UDID" 2>&1); then
    logger "Device '$DEVICE_UDID' is available."
    logger "Device info:"
    echo "$deviceInfo" | jq --raw-input '. as $line | try (fromjson) catch $line'
    isAvailable=1
    break
  elif [[ "${deviceInfo}" == *"failed getting info"* ]]; then
    logger "WARN" "Failed getting info."
  elif [[ "${deviceInfo}" == *"Timed out waiting for response for message"* ]]; then
    # Timed out error.
    # {"channel_id":"com.apple.instruments.server.services.deviceinfo","error":"Timed out waiting for response for message:5 channel:0","level":"error","msg":"failed requesting channel","time":"2023-09-05T15:19:27Z"}
    logger "WARN" "Timed out waiting for response. Device reboot is recommended!"
    isAvailable=1
    break
  else
    logger "WARN" "Device is not found '$DEVICE_UDID'!"
  fi

  logger "WARN" "Waiting for ${POLLING_SEC} seconds."
  sleep "${POLLING_SEC}"
  index+=1
done
index=0

if [[ $isAvailable -eq 0 ]]; then
  logger "ERROR" "Device is not available:"
  echo "$deviceInfo" | jq --raw-input '. as $line | try (fromjson) catch $line'

  now=$(date +%s)
  unavailableSince=$(cat "$deviceUnavailableFile" 2> /dev/null)
  if [[ ! "$unavailableSince" =~ ^[0-9]+$ ]]; then
    unavailableSince=$now
    mkdir -p "$(dirname "$deviceUnavailableFile")"
    echo "$unavailableSince" > "$deviceUnavailableFile"
  fi
  if [[ "$DEVICE_UNAVAILABLE_TIMEOUT" -gt 0 ]] && [[ $((now - unavailableSince)) -ge "$DEVICE_UNAVAILABLE_TIMEOUT" ]]; then
    logger "ERROR" "Device is unavailable for $((now - unavailableSince)) seconds (not more than $DEVICE_UNAVAILABLE_TIMEOUT allowed, is it unpaired?). Exiting!"
    exit 0
  fi
  logger "ERROR" "Restarting!"
  exit 1
fi
rm -f "$deviceUnavailableFile"

#### Detect device OS version
ios17plus=0
userspaceTunnel=0
deviceOsVersion=$(echo "$deviceInfo" | sed -n 's/.*"ProductVersion":"\([^"]*\).*/\1/p')
logger "Detected device os version: $deviceOsVersion"
# removes everything from the first dot '.' onwards
majorOsVersion="${deviceOsVersion%%.*}"
if [[ "$majorOsVersion" -gt 0 ]] 2> /dev/null; then
  logger "Major os version detected as '$majorOsVersion'"
  if [[ "$majorOsVersion" -ge 17 ]]; then
    ios17plus=1
  fi
  # go-ios runs the tunnel in user space over lockdown (CoreDeviceProxy) for the versions after 17.4.0
  IFS=. read -r _ minorOsVersion patchOsVersion <<< "$deviceOsVersion"
  if [[ "$majorOsVersion" -gt 17 ]] ||
    [[ "$majorOsVersion" -eq 17 && $((10#${minorOsVersion:-0} * 1000 + 10#${patchOsVersion:-0})) -gt 4000 ]]; then
    userspaceTunnel=1
  fi
else
  logger "WARN" "Can't detect major os version: $majorOsVersion"
fi

#### Detect device type
# DeviceClass is iPhone, iPad, iPod or AppleTV
deviceClass=$(echo "$deviceInfo" | sed -n 's/.*"DeviceClass":"\([^"]*\).*/\1/p')
case "$deviceClass" in
iPad) deviceType="Tablet" ;;
AppleTV) deviceType="tvOS" ;;
*) deviceType="Phone" ;;
esac
logger "Detected device class: '$deviceClass', device type: '$deviceType'"
# WDA of tvOS is a separate runner with its own xctest bundle, the bundle ids are the same as for iOS.
# Parameters set manually are never overridden.
if [[ "$deviceType" == "tvOS" ]] && [[ -z "${XCTEST_CONFIG}" ]]; then
  XCTEST_CONFIG="WebDriverAgentRunner_tvOS.xctest"
  logger "XCTEST_CONFIG is not set, using '$XCTEST_CONFIG' for tvOS."
fi

#### Run go-ncm and check connection
# go-ncm needs the usb device of a Linux host, the other connections run the tunnel in user space over lockdown
usbOnLinux=0
if [[ ${HOST_OS^^} = "LINUX" && "$DEVICE_CONNECTION" == "usb" ]]; then
  usbOnLinux=1
fi
if [[ "$ios17plus" -eq 1 ]] && [[ "$usbOnLinux" -eq 1 ]]; then
  logger "Starting go-ncm and its reporting on 3030 port."
  # To check 'curl 127.0.0.1:3030/metrics'
  go-ncm --prometheusport=3030 &
  declare -i index=0
  isNcmConnected=0
  # TODO: adjust timeout based on real usage
  while [[ $index -lt 10 ]]; do
    if ! curl -Is 127.0.0.1:3030/metrics | head -1 | grep -q '200'; then
      logger "Ncm '/metrics' endpoint is not available."
    else
      deviceCount=$(curl -s 127.0.0.1:3030/metrics | grep "^device_count" | cut -d ' ' -f2)
      logger "Found $deviceCount device connected with ncm."
      [[ "$deviceCount" -ge 1 ]] && isNcmConnected=1 && break
    fi
    logger "WARN" "Waiting for ${POLLING_SEC} seconds."
    sleep "${POLLING_SEC}"
    index+=1
  done
  index=0

  if [[ $isNcmConnected -eq 0 ]]; then
    logger "ERROR" "Ncm can't connect with device. Restarting!"
    exit 1
  fi
fi

#### Start and check tunnel
if [[ "$ios17plus" -eq 1 && "$usbOnLinux" -eq 0 && "$userspaceTunnel" -eq 0 ]]; then
  logger "WARN" "iOS ${deviceOsVersion} needs the kernel tunnel of go-ncm (usb of a Linux host), the '$DEVICE_CONNECTION' connection has no tunnel: WDA is expected to be started outside the container."
fi
if [[ "$ios17plus" -eq 1 ]] && [[ "$usbOnLinux" -eq 1 || "$userspaceTunnel" -eq 1 ]]; then
  tunnelLogFile="/tmp/log/tunnel.log"
  touch $tunnelLogFile

  tunnelArgs=(--pair-record-path=/var/lib/lockdown --udid="$DEVICE_UDID")
  if [[ "$userspaceTunnel" -eq 1 ]]; then
    # The tunnel runs in user space and is shared with the other containers of the device (the STF provider reaches
    # it with GO_IOS_AGENT_HOST=connector): its API listens on all the interfaces, the go-ios commands below find it
    # there too, and its port is forwarded from the address of the container (go-ios listens on localhost only)
    export GO_IOS_AGENT_HOST=0.0.0.0
    tunnelArgs+=(--userspace)
  fi
  logger "Starting tunnel for --udid=$DEVICE_UDID"
  # the identity of the tunnel is written there, without the usbmuxd of the container the folder may be missing
  mkdir -p /var/lib/lockdown 2> /dev/null
  ios tunnel start "${tunnelArgs[@]}" > "$tunnelLogFile" 2>&1 &

  tail -f "$tunnelLogFile" &

  declare -i index=0
  isTunnelStarted=0
  # TODO: adjust timeout based on real usage
  while [[ $index -lt 10 ]]; do
    if ! curl -o /dev/null -s -w "%{http_code}\n" 127.0.0.1:60105/tunnels | grep -q '200'; then
      logger "Go-ios '/tunnels' endpoint is not available."
    else
      logger "Go-ios '/tunnels' endpoint is available:"
      tunnels=$(curl -s 127.0.0.1:60105/tunnels)
      echo "$tunnels"
      echo "$tunnels" | grep -q "$DEVICE_UDID" && isTunnelStarted=1 && break
    fi
    logger "WARN" "Waiting for ${POLLING_SEC} seconds."
    sleep "${POLLING_SEC}"
    index+=1
  done
  index=0

  # TODO: add reasons processing and possibly exit
  if [[ $isTunnelStarted -eq 0 ]]; then
    logger "ERROR" "Can't start tunnel to device. Restarting!"
    exit 1
  fi

  if [[ "$userspaceTunnel" -eq 1 ]]; then
    tunnelPort=$(echo "$tunnels" | sed -n 's/.*"userspaceTunPort":\([0-9]*\).*/\1/p')
    containerIp=$(hostname -i 2> /dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$')
    if [[ ! "$tunnelPort" -gt 0 ]] 2> /dev/null || [[ -z "$containerIp" ]]; then
      logger "ERROR" "Can't share the tunnel (port '${tunnelPort}', address '${containerIp}'). Restarting!"
      exit 1
    fi
    socat TCP-LISTEN:"$tunnelPort",bind="$containerIp",reuseaddr,fork TCP:127.0.0.1:"$tunnelPort" &
    logger "The tunnel is shared on ${containerIp}:${tunnelPort}, its API on port 60105."
  fi
fi

#### Mount DeveloperDiskImage
logger "Allow to download and mount DeveloperDiskImages automatically."
# Parse error to detect anomaly with mounting and/or pairing. It might be use case when user cleared already trusted computer
# {"err":"failed connecting to image mounter: Could not start service:com.apple.mobile.mobile_image_mounter with reason:'SessionInactive'. Have you mounted the Developer Image?","image":"/tmp/DeveloperDiskImages/16.4.1/DeveloperDiskImage.dmg","level":"error","msg":"error mounting image","time":"2023-08-04T11:25:53Z","udid":"d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"}
res=$(ios image auto --basedir /opt/zebrunner/devimages/ --udid="$DEVICE_UDID" 2>&1)
echo "$res" | jq --raw-input '. as $line | try (fromjson) catch $line'

if [[ "${res}" == *"success mounting image"* ]]; then
  logger "Developer Image mounted successfully."
  sleep 3
#elif [[ "${res}" == *"error mounting image"* ]]; then
#  logger "ERROR" "Developer Image mounting with go-ios is broken."
#  logger "Trying to use pymobiledevice3:"
#  source /opt/zebrunner/venv/bin/activate
#  pyres=$(pymobiledevice3 mounter auto-mount 2>&1)
#  deactivate
#  echo "$pyres"
#  if [[ "${pyres}" == *"mounted successfully"* ]]; then
#    logger "Developer Image mounted successfully with pymobiledevice3."
#    sleep 3
#  else
#    logger "ERROR" "Developer Image mounting is broken with pymobiledevice3:"
#    logger "ERROR" "Exiting!"
#    exit 0
#  fi
else
  logger "ERROR" "Unhandled exception:"
  logger "ERROR" "Exiting!"
  exit 0
fi

#### Check if WDA is already installed
if ios apps --udid="$DEVICE_UDID" | grep -v grep | grep "$WDA_BUNDLEID" > /dev/null 2>&1; then
  logger "'$WDA_BUNDLEID' app is already installed"
else
  logger "'$WDA_BUNDLEID' app is not installed"

  # the container installs WDA on every host: on macOS over the usbmuxd of the host
  if [[ ! -f "$WDA_FILE" ]]; then
    logger "ERROR" "'$WDA_FILE' file is not exist or not a regular file. Exiting!"
    exit 0
  fi

  logger "Installing WDA application on device:"
  wdaInstall=$(ios install --path="$WDA_FILE" --udid="$DEVICE_UDID" 2>&1)
  if [[ $wdaInstall == *'"err":'* ]]; then
    logger "ERROR" "Error while installing WDA_FILE: '$WDA_FILE'."
    echo "$wdaInstall" | jq --raw-input '. as $line | try (fromjson) catch $line'
    logger "ERROR" "Trying to uninstall WDA:"
    wdaUninstall=$(ios uninstall "$WDA_BUNDLEID" --udid="$DEVICE_UDID" 2>&1)
    echo "$wdaUninstall" | jq --raw-input '. as $line | try (fromjson) catch $line'
    logger "ERROR" "Exiting!"
    exit 0
  fi
fi

#### Start WDA

runWda() {
  touch "${WDA_LOG_FILE}"
  tail -f "${WDA_LOG_FILE}" &
  # This is temporary solution for modal dialogs which prevent WDA startup.
  logger "Resetting springboard process and waiting for 5 seconds."
  ios kill com.apple.springboard --udid="$DEVICE_UDID"
  sleep 5

  declare -i index=0
  isWdaStarted=0
  wdaRunOutputFile="/tmp/log/wda-run.out"
  while [[ $index -lt 10 ]]; do
    if ! (pgrep -f "ios runwda" > /dev/null 2>&1); then
      # The output is also kept to detect the failures that a retry can't fix
      ios runwda \
        --bundleid="${WDA_BUNDLEID:="com.facebook.WebDriverAgentRunner.xctrunner"}" \
        --testrunnerbundleid="${TEST_RUNNER_BUNDLE_ID:=$WDA_BUNDLEID}" \
        --xctestconfig="${XCTEST_CONFIG:="WebDriverAgentRunner.xctest"}" \
        --env USE_PORT="$WDA_PORT" \
        --env MJPEG_SERVER_PORT="$MJPEG_PORT" \
        --env UITEST_DISABLE_ANIMATIONS=YES \
        --log-output="${WDA_LOG_FILE}" \
        --udid="$DEVICE_UDID" 2>&1 | tee "$wdaRunOutputFile"
      if grep -qi "invalid code signature" "$wdaRunOutputFile"; then
        logger "ERROR" "WDA can't be launched: invalid code signature, inadequate entitlements or its profile is not trusted by the user."
        logger "ERROR" "Re-sign WDA with a valid profile and trust it on the device. Exiting!"
        exitInBackground 0
      fi
      logger "WARN" "'ios runwda' process broke. Attempt to recover."
      isWdaStarted=0
    else
      logger "WARN" "WDA already started"
      isWdaStarted=1
      break
    fi
    sleep 1
    index+=1
  done
  index=0

  if [[ $isWdaStarted -eq 0 ]]; then
    logger "ERROR" "Can't run WDA. Exiting!"
    exitInBackground 0
  fi
}

forwardPort() {
  port=$1
  logger "Forwarding port: $port"

  declare -i index=0
  isPortForwarded=0
  # TODO: adjust timeout based on real usage
  while [[ $index -lt 30 ]]; do
    if ! (pgrep -f "ios forward $port" > /dev/null 2>&1); then
      ios forward "$port" "$port" --udid="$DEVICE_UDID" > /dev/null 2>&1
      logger "WARN" "Port '$port' forwarding broke. Attempt to recover."
      isPortForwarded=0
    else
      logger "WARN" "Port '$port' already forwarded"
      isPortForwarded=1
      break
    fi
    sleep 1
    index+=1
  done
  index=0

  if [[ $isPortForwarded -eq 0 ]]; then
    logger "ERROR" "Can't forward port '$port'. Restarting!"
    exitInBackground 1
  fi
}

if [[ ${HOST_OS^^} = "LINUX" ]]; then
  if ! isWdaUp; then
    logger "WARN" "Running WDA not detected."

    logger "Starting WebDriverAgent application on port '$WDA_PORT'."
    runWda &
    sleep 3

    # #148: ios: reuse proxy for redirecting wda requests through appium container
    forwardPort "$WDA_PORT" &
    sleep 1
    forwardPort "$MJPEG_PORT" &
  fi
else
  # On macOS platform reset springboard only for ios version lower than 17
  if [[ "$ios17plus" -eq 0 ]]; then
    logger "Resetting springboard process and waiting for 5 seconds."
    ios kill com.apple.springboard --udid="$DEVICE_UDID"
    sleep 5
  fi
  forwardPort "$WDA_PORT" &
  sleep 1
  forwardPort "$MJPEG_PORT" &
  # WDA started on macOS by the host (Xcode, a script of the host) is used as is, otherwise the container starts it
  declare -i index=0
  while [[ $index -lt 5 ]] && ! isWdaUp; do
    sleep 1
    index+=1
  done
  index=0
  if isWdaUp; then
    logger "WDA started outside the container is used."
  else
    logger "WARN" "Running WDA not detected."
    logger "Starting WebDriverAgent application on port '$WDA_PORT'."
    runWda &
  fi
fi

#### Wait for WDA start
waitForWda

# TODO: to  improve better 1st super slow session startup we have to investigate extra xcuitest caps: https://github.com/appium/appium-xcuitest-driver
# customSnapshotTimeout, waitForIdleTimeout, animationCoolOffTimeout etc

# TODO: also find a way to override default snapshot generation 60 sec timeout building WebDriverAgent.ipa

#### Entrypoint holder
holdWda
