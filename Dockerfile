FROM alpine:3.19.1

ENV DEBIAN_FRONTEND=noninteractive

ENV DEVICE_UDID=
ENV DEVICE_BUS=/dev/bus/usb/003/011

ENV POLLING_SEC=5

# Debug mode vars
ENV DEBUG=false
ENV DEBUG_TIMEOUT=3600
ENV VERBOSE=false

# iOS envs
ENV WDA_HOST=localhost
ENV WDA_PORT=8100
ENV MJPEG_PORT=8101
ENV WDA_WAIT_TIMEOUT=30
ENV WDA_LOG_FILE=/tmp/log/wda.log
ENV WDA_BUNDLEID=com.facebook.WebDriverAgentRunner.xctrunner
ENV WDA_FILE=/tmp/zebrunner/WebDriverAgent.ipa

RUN mkdir /tmp/log/; \
    mkdir /tmp/zebrunner/

# Usbmuxd settings "host:port"
ENV USBMUXD_SOCKET_ADDRESS=

COPY debug.sh /opt

RUN apk add --no-cache bash

# busybox-extras include (unzip, wget, iputils-ping (ping), nc) packages
RUN apk update; \
    apk upgrade; \
    apk add nano jq curl socat libc6-compat; \
    apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing --repository http://dl-cdn.alpinelinux.org/alpine/edge/main usbmuxd; \
    apk add busybox-extras

#=============
# Set WORKDIR
#=============
WORKDIR /root

#Grab gidevice from github and extract it in a folder
RUN wget https://github.com/danielpaulus/go-ios/releases/download/v1.0.120/go-ios-linux.zip
# https://github.com/danielpaulus/go-ios/releases/latest/download/go-ios-linux.zip
RUN unzip go-ios-linux.zip -d /usr/local/bin

RUN ios --version

# Copy entrypoint script
ADD entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
