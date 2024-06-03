#!/bin/bash

. /opt/debug.sh
. /opt/logger.sh

logger "INFO" "\n\n\n\t\tMCLOUD-IOS-CONNECTOR\n\n"


#### Prepare for connection
if [[ -z $USBMUXD_SOCKET_ADDRESS ]]; then
  logger "Start containerized usbmuxd service/process"
  usbmuxd -f &
  sleep 2
  # socat server to share usbmuxd socket via TCP
  socat TCP-LISTEN:2222,reuseaddr,fork UNIX-CONNECT:/var/run/usbmuxd &
else
  # rm /var/run/usbmuxd in advance to be able to start socat and join it to $USBMUXD_SOCKET_ADDRESS
  # rm -f /var/run/usbmuxd
  # socat UNIX-LISTEN:/var/run/usbmuxd,fork,reuseaddr,mode=777 TCP:"$USBMUXD_SOCKET_ADDRESS" &
  socat TCP-LISTEN:2222,reuseaddr,fork TCP:"$USBMUXD_SOCKET_ADDRESS" &
fi


#### Check the connection
declare -i index=0
isAvailable=0
while [[ $index -lt 10 ]]; do
  if deviceInfo=$(ios info --udid="$DEVICE_UDID" 2>&1); then
    logger "Device '$DEVICE_UDID' is available."
    logger "Device info:\n$deviceInfo"
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

if [[ $isAvailable -eq 0 ]]; then
  logger "ERROR" "Device is not available:\n$deviceInfo\nRestarting!"
  exit 1
fi


#### Mount DeveloperDiscImage
logger "Allow to download and mount DeveloperDiskImages automatically"
# Parse error to detect anomaly with mounting and/or pairing. It might be use case when user cleared already trusted computer
# {"err":"failed connecting to image mounter: Could not start service:com.apple.mobile.mobile_image_mounter with reason:'SessionInactive'. Have you mounted the Developer Image?","image":"/tmp/DeveloperDiskImages/16.4.1/DeveloperDiskImage.dmg","level":"error","msg":"error mounting image","time":"2023-08-04T11:25:53Z","udid":"d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"}
if res=$(ios image auto --basedir /tmp/DeveloperDiskImages --udid="$DEVICE_UDID" 2>&1); then
  logger "Developer Image auto mount succeed:\n$res"
  sleep 3
elif [[ "${res}" == *"error mounting image"* ]]; then
  logger "ERROR" "Developer Image mounting is broken:\n$res\nRestarting!"
  exit 0
else
  logger "ERROR" "Unhandled exception:\n$res\nExiting!"
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
  ios install --path="$WDA_FILE" --udid="$DEVICE_UDID"
  if [[ $? -eq 1 ]]; then
    logger "ERROR" "Unable to install '$WDA_FILE'. Exiting!"
    exit 0
  fi
fi


#### Start WDA
# no need to launch springboard as it is already started. below command doesn't activate it!
#logger "Activating default com.apple.springboard during WDA startup"
#ios launch com.apple.springboard
touch "${WDA_LOG_FILE}"
# verify if wda is already started and reuse this session

curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK'
if [[ $? -ne 0 ]]; then
  logger "Existing WDA not detected."

  #Start the WDA service on the device using the WDA bundleId
  logger "Starting WebDriverAgent application on port $WDA_PORT"
  ios runwda \
    --env USE_PORT="$WDA_PORT" \
    --env MJPEG_SERVER_PORT="$MJPEG_PORT" \
    --env UITEST_DISABLE_ANIMATIONS=YES \
    --udid="$DEVICE_UDID" > "${WDA_LOG_FILE}" 2>&1 &

  # #148: ios: reuse proxy for redirecting wda requests through appium container
  ios forward "$WDA_PORT" "$WDA_PORT" --udid="$DEVICE_UDID" > /dev/null 2>&1 &
  ios forward "$MJPEG_PORT" "$MJPEG_PORT" --udid="$DEVICE_UDID" > /dev/null 2>&1 &
fi

tail -f "${WDA_LOG_FILE}" &


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
  logger "WARN" "Bad or no response from 'http://${WDA_HOST}:${WDA_PORT}/status'.\nOne more attempt."
  sleep 2
done

if [[ $wdaStarted -eq 0 ]]; then
  logger "ERROR" "No response from WDA, or WDA is unhealthy!. Restarting!"
  exit 1
fi

#TODO: to  improve better 1st super slow session startup we have to investigate extra xcuitest caps: https://github.com/appium/appium-xcuitest-driver
#customSnapshotTimeout, waitForIdleTimeout, animationCoolOffTimeout etc

#TODO: also find a way to override default snapshot generation 60 sec timeout building WebDriverAgent.ipa


#### Healthcheck
while :; do
  sleep $WDA_WAIT_TIMEOUT
  curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK'
  if [[ $? -eq 0 ]]; then
    logger "Wda is healthy."
  else
    logger "ERROR" "WDA is unhealthy. Restarting."
    break
  fi
done

exit 1
