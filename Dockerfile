FROM alpine:3.19.1

ENV DEBIAN_FRONTEND=noninteractive

ENV DEVICE_UDID=
ENV DEVICE_BUS=/dev/bus/usb/003/011

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

#COPY debug.sh /opt

RUN apk add --no-cache bash

#Setup some tools
RUN apk update && apk add iputils-ping nano jq curl socat

#=============
# Set WORKDIR
#=============
WORKDIR /root

#Grab gidevice from github and extract it in a folder
RUN wget https://github.com/danielpaulus/go-ios/releases/download/v1.0.120/go-ios-linux.zip
# https://github.com/danielpaulus/go-ios/releases/latest/download/go-ios-linux.zip
RUN unzip go-ios-linux.zip -d /usr/local/bin

#RUN ios --version

# Copy entrypoint script
ADD entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
