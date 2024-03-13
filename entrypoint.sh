#!/bin/bash

sleep infinity
. /opt/debug.sh

#### prepare to connection
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


#### connect to the device
declare -i index=0
available=0
while [[ $available -eq 0 ]] && [[ $index -lt 10 ]]
do
    available=`ios list | grep -c $DEVICE_UDID`
    if [[ $available -eq 1 ]]; then
        break
    fi
    sleep ${ADB_POLLING_SEC}
    index+=1
done

if [[ $available -eq 1 ]]; then
    echo "Device is available"
else
    echo "Device is not available!"
    exit 1
fi

#### check the device state


#### healthcheck
echo "----"
echo "Connecting to ${WDA_HOST} ${MJPEG_PORT} using netcat..."
nc ${WDA_HOST} ${MJPEG_PORT}
echo "netcat connection is closed."
exit 1
