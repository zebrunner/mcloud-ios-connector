#!/bin/bash

. /opt/debug.sh


#### Prepare for connection
if [[ -z $USBMUXD_SOCKET_ADDRESS ]]; then
  echo "Start containerized usbmuxd service/process"
  usbmuxd -f &
  sleep 2
  # socat server to share usbmuxd socket via TCP
  socat TCP-LISTEN:22,reuseaddr,fork UNIX-CONNECT:/var/run/usbmuxd &
else
  # rm /var/run/usbmuxd in advance to be able to start socat and join it to $USBMUXD_SOCKET_ADDRESS
  rm -f /var/run/usbmuxd
  socat UNIX-LISTEN:/var/run/usbmuxd,fork,reuseaddr,mode=777 TCP:$USBMUXD_SOCKET_ADDRESS &
fi


#### Check the connection
declare -i index=0
available=0
while [[ $available -eq 0 ]] && [[ $index -lt 10 ]]; do
  available=$(ios list | grep -c $DEVICE_UDID)
  if [[ $available -eq 1 ]]; then
    echo "Device '$DEVICE_UDID' is available."
    break
  fi
  echo "Can't find UDID '$DEVICE_UDID' in 'ios list'. Waiting for ${POLLING_SEC} seconds."
  sleep ${POLLING_SEC}
  index+=1
done

if [[ $available -ne 1 ]]; then
  echo "Device is not available. Restarting."
  exit 1
fi


#### Detect device parameters
echo "[$(date +'%d/%m/%Y %H:%M:%S')] populating device info"
deviceInfo=$(ios info --udid=$DEVICE_UDID 2>&1)
echo "device info: $deviceInfo"

if [[ "${deviceInfo}" == *"failed getting info"* ]]; then
  echo "ERROR! failed getting info. No sense to proceed with services startup!"
  exit 0
fi

export PLATFORM_VERSION=$(echo $deviceInfo | jq -r ".ProductVersion | select( . != null )")
deviceClass=$(echo $deviceInfo | jq -r ".DeviceClass | select( . != null )")
export DEVICETYPE='Phone'
if [ "$deviceClass" = "iPad" ]; then
  export DEVICETYPE='Tablet'
fi
if [ "$deviceClass" = "AppleTV" ]; then
  export DEVICETYPE='tvOS'
fi

echo "Detected device characteristics:"
echo "PLATFORM_VERSION=$PLATFORM_VERSION"
echo "deviceClass=$deviceClass"
echo "DEVICETYPE=$DEVICETYPE"

# Parse output to detect Timeoud out error.
# {"channel_id":"com.apple.instruments.server.services.deviceinfo","error":"Timed out waiting for response for message:5 channel:0","level":"error","msg":"failed requesting channel","time":"2023-09-05T15:19:27Z"}

if [[ "${deviceInfo}" == *"Timed out waiting for response for message"* ]]; then
  echo "ERROR! Timed out waiting for response detected."
  if [[ "${DEVICETYPE}" == "tvOS" ]]; then
    echo "ERROR! TV reboot is required! Exiting without restart..."
    exit 0
  else
    echo "WARN! device reboot is recommended!"
  fi
fi


#### Mount DeveloperDiscImage
if [[ "${PLATFORM_VERSION}" == "17."* ]] || [[ "${DEVICETYPE}" == "tvOS" ]]; then
  echo "Mounting iOS via Linux container not supported! WDA should be compiled and started via xcode!"
  echo "wda install and startup steps will be skipped from appium container..."

  # start proxy forward to device
  ios forward $WDA_PORT $WDA_PORT --udid=$DEVICE_UDID >/dev/null 2>&1 &
  ios forward $MJPEG_PORT $MJPEG_PORT --udid=$DEVICE_UDID >/dev/null 2>&1 &
  return 0
fi

echo "[$(date +'%d/%m/%Y %H:%M:%S')] Allow to download and mount DeveloperDiskImages automatically"
res=$(ios image auto --basedir /tmp/DeveloperDiskImages --udid=$DEVICE_UDID 2>&1)
echo $res

# Parse error to detect anomaly with mounting and/or pairing. It might be use case when user cleared already trusted computer
# {"err":"failed connecting to image mounter: Could not start service:com.apple.mobile.mobile_image_mounter with reason:'SessionInactive'. Have you mounted the Developer Image?","image":"/tmp/DeveloperDiskImages/16.4.1/DeveloperDiskImage.dmg","level":"error","msg":"error mounting image","time":"2023-08-04T11:25:53Z","udid":"d6afc6b3a65584ca0813eb8957c6479b9b6ebb11"}

if [[ "${res}" == *"error mounting image"* ]]; then
  echo "ERROR! Mounting is broken due to the invalid paring. Please re pair again!"
  exit 1
else
  echo "Developer Image auto mount succeed."
  sleep 3
fi


#### Check if WDA is already installed
ios apps --udid=$DEVICE_UDID | grep -v grep | grep $WDA_BUNDLEID >/dev/null 2>&1
if [[ ! $? -eq 0 ]]; then
  echo "$WDA_BUNDLEID app is not installed"

  if [ ! -f $WDA_FILE ]; then
    echo "ERROR! WebDriverAgent.ipa file is not exist or not a regular file!"
    exit 0
  fi

  echo "[$(date +'%d/%m/%Y %H:%M:%S')] Installing WDA application on device"
  ios install --path="$WDA_FILE" --udid=$DEVICE_UDID
  if [ $? == 1 ]; then
    echo "ERROR! Unable to install WebDriverAgent.ipa!"
    exit 0
  fi
else
  echo "$WDA_BUNDLEID app is already installed"
fi


#### Start WDA
# no need to launch springboard as it is already started. below command doesn't activate it!
#echo "[$(date +'%d/%m/%Y %H:%M:%S')] Activating default com.apple.springboard during WDA startup"
#ios launch com.apple.springboard
touch ${WDA_LOG_FILE}
# verify if wda is already started and reuse this session
curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK'
if [ $? -eq 1 ]; then
  echo "Existing WDA not detected"

  schema=WebDriverAgentRunner
  if [ "$DEVICETYPE" == "tvOS" ]; then
    schema=WebDriverAgentRunner_tvOS
  fi

  #Start the WDA service on the device using the WDA bundleId
  echo "[$(date +'%d/%m/%Y %H:%M:%S')] Starting WebDriverAgent application on port $WDA_PORT"
  ios runwda --bundleid=$WDA_BUNDLEID --testrunnerbundleid=$WDA_BUNDLEID --xctestconfig=${schema}.xctest --env USE_PORT=$WDA_PORT --env MJPEG_SERVER_PORT=$MJPEG_PORT --env UITEST_DISABLE_ANIMATIONS=YES --udid=$DEVICE_UDID > ${WDA_LOG_FILE} 2>&1 &

  # #148: ios: reuse proxy for redirecting wda requests through appium container
  ios forward $WDA_PORT $WDA_PORT --udid=$DEVICE_UDID >/dev/null 2>&1 &
  ios forward $MJPEG_PORT $MJPEG_PORT --udid=$DEVICE_UDID >/dev/null 2>&1 &
fi

tail -f ${WDA_LOG_FILE} &


#### Wait for WDA start
startTime=$(date +%s)
idleTimeout=$WDA_WAIT_TIMEOUT
wdaStarted=0
while [ $((startTime + idleTimeout)) -gt "$(date +%s)" ]; do
  curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK'
  if [ $? -eq 0 ]; then
    echo "Wda status is ok."
    wdaStarted=1
    break
  fi
  sleep 1
done

if [ $wdaStarted -eq 0 ]; then
  echo "WDA is unhealthy!"
  # Destroy appium process as there is no sense to continue with undefined WDA_HOST ip!
  pkill node
  exit 1
fi

#TODO: to  improve better 1st super slow session startup we have to investigate extra xcuitest caps: https://github.com/appium/appium-xcuitest-driver
#customSnapshotTimeout, waitForIdleTimeout, animationCoolOffTimeout etc

#TODO: also find a way to override default snapshot generation 60 sec timeout building WebDriverAgent.ipa


#### Healthcheck
echo "Connecting to ${WDA_HOST} ${MJPEG_PORT} using netcat..."
nc ${WDA_HOST} ${MJPEG_PORT}
echo "${WDA_HOST} ${MJPEG_PORT} connection closed. Restarting."
exit 1
