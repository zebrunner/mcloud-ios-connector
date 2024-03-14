#!/bin/bash

. /opt/debug.sh


#### prepare for connection
if [[ -z $USBMUXD_SOCKET_ADDRESS ]]; then
    echo "start containerized usbmuxd service/process"
    usbmuxd -f &
    sleep 2
    # socat server to share usbmuxd socket via TCP
    socat TCP-LISTEN:22,reuseaddr,fork UNIX-CONNECT:/var/run/usbmuxd &
else
    # rm /var/run/usbmuxd in advance to be able to start socat and join it to $USBMUXD_SOCKET_ADDRESS
    rm -f /var/run/usbmuxd
    socat UNIX-LISTEN:/var/run/usbmuxd,fork,reuseaddr,mode=777 TCP:$USBMUXD_SOCKET_ADDRESS &
fi


#### check the connection
declare -i index=0
available=0
while [[ $available -eq 0 ]] && [[ $index -lt 10 ]]
do
    available=`ios list | grep -c $DEVICE_UDID`
    if [[ $available -eq 1 ]]; then
        break
    fi
    sleep ${POLLING_SEC}
    index+=1
done

if [[ $available -eq 1 ]]; then
    echo "Device is available"
else
    echo "Device is not available!"
    exit 1
fi

#### Check if WDA is already installed
ios apps --udid=$DEVICE_UDID | grep -v grep | grep $WDA_BUNDLEID > /dev/null 2>&1
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

#### start WDA
# no need to launch springboard as it is already started. below command doesn't activate it!
#echo "[$(date +'%d/%m/%Y %H:%M:%S')] Activating default com.apple.springboard during WDA startup"
#ios launch com.apple.springboard
touch ${WDA_LOG_FILE}
# verify if wda is already started and reuse this session
curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK'
if [ $? -eq 1 ]; then
    echo "existing WDA not detected"

    schema=WebDriverAgentRunner
    if [ "$DEVICETYPE" == "tvOS" ]; then
        schema=WebDriverAgentRunner_tvOS
    fi

    #Start the WDA service on the device using the WDA bundleId
    echo "[$(date +'%d/%m/%Y %H:%M:%S')] Starting WebDriverAgent application on port $WDA_PORT"
    ios runwda --bundleid=$WDA_BUNDLEID --testrunnerbundleid=$WDA_BUNDLEID --xctestconfig=${schema}.xctest --env USE_PORT=$WDA_PORT --env MJPEG_SERVER_PORT=$MJPEG_PORT --env UITEST_DISABLE_ANIMATIONS=YES --udid=$DEVICE_UDID > ${WDA_LOG_FILE} 2>&1 &

    # #148: ios: reuse proxy for redirecting wda requests through appium container
    ios forward $WDA_PORT $WDA_PORT --udid=$DEVICE_UDID > /dev/null 2>&1 &
    ios forward $MJPEG_PORT $MJPEG_PORT --udid=$DEVICE_UDID > /dev/null 2>&1 &
fi

tail -f ${WDA_LOG_FILE} &

# wait until WDA starts
startTime=$(date +%s)
idleTimeout=$WDA_WAIT_TIMEOUT
wdaStarted=0
while [ $(( startTime + idleTimeout )) -gt "$(date +%s)" ]; do
    curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK'
    if [ $? -eq 0 ]; then
        echo "wda status is ok."
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


#### healthcheck
echo "Connecting to ${WDA_HOST} ${MJPEG_PORT} using netcat..."
nc ${WDA_HOST} ${MJPEG_PORT}
echo "netcat connection is closed."
exit 1
