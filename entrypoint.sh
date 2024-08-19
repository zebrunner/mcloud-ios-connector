#!/bin/bash

. /opt/debug.sh
. /opt/logger.sh

logger "INFO" "\n\n\n\t\tMCLOUD-IOS-CONNECTOR\n\n"


#### Establish and check usbmuxd connection
# Check if $USBMUXD_PORT port is free
declare -i index=0
isLocalPortFree=0
# TODO: adjust timeout based on real usage
while [[ $index -lt 10 ]]; do
  # If we can connect to the port, then someone is already waiting for a connection on this port
  if nc -z localhost "$USBMUXD_PORT"; then
    logger "ERROR" "localhost $USBMUXD_PORT port is busy. One more attempt..."
    index+=1
    sleep 1
  else
    isLocalPortFree=1
    break
  fi
done; index=0

if [[ $isLocalPortFree -eq 1 ]]; then
  logger "localhost $USBMUXD_PORT port is free."
else
  logger "ERROR" "localhost $USBMUXD_PORT port is busy. Exiting!"
  exit 0
fi

# Check if selected usbmuxd socket available
declare -i index=0
isUsbmuxdConnected=0
if [[ -z $USBMUXD_SOCKET_ADDRESS ]]; then
  logger "Start containerized usbmuxd service/process."
  usbmuxd -f &
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
  done; index=0
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
  done; index=0
fi

if [[ $isUsbmuxdConnected -eq 1 ]]; then
  logger "Usbmuxd socket is available."
else
  logger "ERROR" "Usbmuxd socket is not available. Exiting!"
  exit 0
fi

# Check if localhost $USBMUXD_PORT port is accessible now
declare -i index=0
isPortAccessible=0
while [[ $index -lt 10 ]]; do
  if ! nc -z localhost "$USBMUXD_PORT"; then
    logger "ERROR" "Usbmuxd forwarding is not established. One more attempt..."
    index+=1
    sleep 1
  else
    isPortAccessible=1
    break
  fi
done; index=0

if [[ $isPortAccessible -eq 1 ]]; then
  logger "Usbmuxd forwarding established."
else
  logger "ERROR" "Usbmuxd forwarding is not established. Exiting!"
  exit 0
fi


#### Check device connection
declare -i index=0
isAvailable=0
while [[ $index -lt 10 ]]; do
  if deviceInfo=$(ios info --udid="$DEVICE_UDID" 2>&1); then
    logger "Device '$DEVICE_UDID' is available."
    logger "Device info:"
    echo "$deviceInfo" | jq
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
done; index=0

if [[ $isAvailable -eq 0 ]]; then
  logger "ERROR" "Device is not available:"
  echo "$deviceInfo" | jq
  logger "ERROR" "Restarting!"
  exit 1
fi


#### Detect OS version and accordingly run go-ncm
ios17plus=0
deviceOsVersion=$(echo "$deviceInfo" | sed -n 's/.*"ProductVersion":"\([^"]*\).*/\1/p')
logger "Detected device os version: $deviceOsVersion"
# removes everything from the first dot '.' onwards
majorOsVersion="${deviceOsVersion%%.*}"
if [[ "$majorOsVersion" -gt 0 ]] 2>/dev/null; then
  logger "Major os version detected as '$majorOsVersion'"
  if [[ "$majorOsVersion" -ge 17 ]]; then
    ios17plus=1
    logger "Running go-ncm and reporting on 3030 port."
    # To check 'curl localhost:3030/metrics'
    go-ncm --prometheusport=3030 &
  fi
else
  logger "WARN" "Can't detect major os version: $majorOsVersion"
fi


#### Check go-ncm connection
if [[ "$ios17plus" -eq 1 ]]; then
  logger "Starting ncm (Network Control Model)."
  declare -i index=0
  isNcmConnected=0
  # TODO: adjust timeout based on real usage
  while [[ $index -lt 10 ]]; do
    curl -Is localhost:3030/metrics | head -1 | grep -q '200 OK'
    if [[ $? -ne 0 ]]; then
      logger "Ncm '/metrics' endpoint is not available."
    else
      deviceCount=$(curl -s localhost:3030/metrics | grep "^device_count" | cut -d ' ' -f2)
      logger "Found $deviceCount device connected with ncm."
      [[ "$deviceCount" -ge 1 ]] && isNcmConnected=1 && break
    fi
    logger "WARN" "Waiting for ${POLLING_SEC} seconds."
    sleep "${POLLING_SEC}"
    index+=1
  done; index=0

  if [[ $isNcmConnected -eq 0 ]]; then
    logger "ERROR" "Ncm can't connect with device. Restarting!"
    exit 1
  fi
fi


#### Start and check tunnel
if [[ "$ios17plus" -eq 1 ]]; then
  tunnelLogFile="/tmp/log/tunnel.log"
  touch $tunnelLogFile

  logger "Starting tunnel for --udid=$DEVICE_UDID"
  ios tunnel start --pair-record-path=/var/lib/lockdown --udid="$DEVICE_UDID" > "$tunnelLogFile" 2>&1 &

  tail -f "$tunnelLogFile" &

  declare -i index=0
  isTunnelStarted=0
  # TODO: adjust timeout based on real usage
  while [[ $index -lt 10 ]]; do
    curl -Is localhost:60105/tunnels | head -1 | grep -q '200 OK'
    if [[ $? -ne 0 ]]; then
      logger "Go-ios '/tunnels' endpoint is not available."
    else
      logger "Go-ios '/tunnels' endpoint is available:"
      tunnels=$(curl -s localhost:60105/tunnels)
      echo "$tunnels"
      echo "$tunnels" | grep -q "$DEVICE_UDID" && isTunnelStarted=1 && break
    fi
    logger "WARN" "Waiting for ${POLLING_SEC} seconds."
    sleep "${POLLING_SEC}"
    index+=1
  done; index=0

  # TODO: add reasons processing and possibly exit
  if [[ $isTunnelStarted -eq 0 ]]; then
    logger "ERROR" "Can't start tunnel to device. Restarting!"
    exit 1
  fi
fi


#### Mount DeveloperDiscImage
logger "Allow to download and mount DeveloperDiskImages automatically."
# Parse error to detect anomaly with mounting and/or pairing. It might be use case when user cleared already trusted computer
# {"err":"failed connecting to image mounter: Could not start service:com.apple.mobile.mobile_image_mounter with reason:'SessionInactive'. Have you mounted the Developer Image?","image":"/tmp/DeveloperDiskImages/16.4.1/DeveloperDiskImage.dmg","level":"error","msg":"error mounting image","time":"2023-08-04T11:25:53Z","udid":"d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"}
if res=$(ios image auto --basedir /tmp/DeveloperDiskImages --udid="$DEVICE_UDID" 2>&1); then
  logger "Developer Image auto mount succeed:"
  echo "$res" | jq
  sleep 3
elif [[ "${res}" == *"error mounting image"* ]]; then
  logger "ERROR" "Developer Image mounting is broken:"
  echo "$res" | jq
  logger "ERROR" "Restarting!"
  exit 0
else
  logger "ERROR" "Unhandled exception:"
  echo "$res" | jq
  logger "ERROR" "Exiting!"
  exit 0
fi


#### Check if WDA is already installed
if ios apps --udid="$DEVICE_UDID" | grep -v grep | grep "$WDA_BUNDLEID" > /dev/null 2>&1; then
  logger "'$WDA_BUNDLEID' app is already installed"
else
  logger "'$WDA_BUNDLEID' app is not installed"

  if [[ ! -f "$WDA_FILE" ]]; then
    logger "ERROR" "'$WDA_FILE' file is not exist or not a regular file. Exiting!"
    exit 0
  fi

  logger "Installing WDA application on device:"
  wdaInstall=$(ios install --path="$WDA_FILE" --udid="$DEVICE_UDID" 2>&1)
  if [[ $wdaInstall == *'"err":'* ]]; then
    logger "ERROR" "Error while installing WDA_FILE: '$WDA_FILE'."
    echo "$wdaInstall" | jq
    logger "ERROR" "Trying to uninstall WDA:"
    wdaUninstall=$(ios uninstall "$WDA_BUNDLEID" --udid="$DEVICE_UDID" 2>&1)
    echo "$wdaUninstall" | jq
    logger "ERROR" "Exiting!"
    exit 0
  fi
fi


#### Start WDA
# No need to launch springboard as it is already started. Below command doesn't activate it!
# logger "Activating default com.apple.springboard during WDA startup"
# ios launch com.apple.springboard
touch "${WDA_LOG_FILE}"
# verify if wda is already started and reuse this session

runWda() {
  declare -i index=0
  isWdaStarted=0
  while [[ $index -lt 10 ]]; do
    if ! (pgrep -f "ios runwda" > /dev/null 2>&1); then
      ios runwda \
        --env USE_PORT="$WDA_PORT" \
        --env MJPEG_SERVER_PORT="$MJPEG_PORT" \
        --env UITEST_DISABLE_ANIMATIONS=YES \
        --udid="$DEVICE_UDID" > "${WDA_LOG_FILE}" 2>&1
      logger "WARN" "'ios runwda' process broke. Attempt to recover."
      isWdaStarted=0
    else
      logger "WARN" "WDA already started"
      isWdaStarted=1
      break
    fi
    sleep 1
    index+=1
  done; index=0

  if [[ $isWdaStarted -eq 0 ]]; then
    logger "ERROR" "Can't run WDA. Restarting!"
    exit 1
  fi
}

forwardPort() {
  if [[ -n $1 ]]; then
    port=$1
  else
    logger "WARN" "Port value is empty or not provided"
    return 1
  fi

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
  done; index=0

  if [[ $isPortForwarded -eq 0 ]]; then
    logger "ERROR" "Can't forward port '$port'. Restarting!"
    exit 1
  fi
}

curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK'
if [[ $? -ne 0 ]]; then
  logger "WARN" "Existing WDA not detected."

  logger "Starting WebDriverAgent application on port '$WDA_PORT'."
  runWda &

  # #148: ios: reuse proxy for redirecting wda requests through appium container
  forwardPort "$WDA_PORT" &
  forwardPort "$MJPEG_PORT" &
fi

tail -f "${WDA_LOG_FILE}" | jq &


#### Wait for WDA start
startTime=$(date +%s)
wdaStarted=0
while [[ $((startTime + WDA_WAIT_TIMEOUT)) -gt "$(date +%s)" ]]; do
  curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK'
  if [[ $? -eq 0 ]]; then
    logger "Wda started successfully!"
    wdaStarted=1
    break
  fi
  logger "WARN" "Bad or no response from 'http://${WDA_HOST}:${WDA_PORT}/status'. One more attempt..."
  sleep 2
done

if [[ $wdaStarted -eq 0 ]]; then
  logger "ERROR" "No response from WDA, or WDA is unhealthy. Restarting!"
  exit 1
fi

# TODO: to  improve better 1st super slow session startup we have to investigate extra xcuitest caps: https://github.com/appium/appium-xcuitest-driver
# customSnapshotTimeout, waitForIdleTimeout, animationCoolOffTimeout etc

# TODO: also find a way to override default snapshot generation 60 sec timeout building WebDriverAgent.ipa


#### Healthcheck
while :; do
  sleep "$WDA_WAIT_TIMEOUT"
  curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK'
  if [[ $? -eq 0 ]]; then
    logger "Wda is healthy."
  else
    logger "ERROR" "WDA is unhealthy. Restarting!"
    break
  fi
done

exit 1
