FROM alpine:3.20.2
# In case  of any build errors try to use 'FROM --platform=linux/amd64 ...'

ENV DEBIAN_FRONTEND=noninteractive \
    DEVICE_UDID='' \
    DEVICE_BUS=/dev/bus/usb/003/011 \
    POLLING_SEC=5 \
    # Debug mode vars
    DEBUG=false \
    DEBUG_TIMEOUT=3600 \
    VERBOSE=false \
    # Logger
    LOGGER_LEVEL=INFO \
    # iOS envs
    WDA_HOST=localhost \
    WDA_PORT=8100 \
    MJPEG_PORT=8101 \
    WDA_WAIT_TIMEOUT=30 \
    WDA_LOG_FILE=/tmp/log/wda.log \
    WDA_BUNDLEID=com.facebook.WebDriverAgentRunner.xctrunner \
    WDA_FILE=/tmp/zebrunner/WebDriverAgent.ipa \
    # Usbmuxd settings "host:port"
    USBMUXD_SOCKET_ADDRESS='' \
    USBMUXD_PORT=2222

WORKDIR /root

RUN mkdir /tmp/log/ ;\
    mkdir /tmp/zebrunner/ ;\
    # busybox-extras include (unzip, wget, iputils-ping (ping), nc) packages
    apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing \
        bash nano jq curl socat libc6-compat busybox-extras libimobiledevice-glue libusb libimobiledevice;\
    # apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing usbmuxd ;\
    # Grab go-ios from github and extract it in a folder
    # https://github.com/danielpaulus/go-ios/releases/latest/download/go-ios-linux.zip
    wget https://github.com/danielpaulus/go-ios/releases/download/v1.0.135/go-ios-linux.zip &&\
    unzip go-ios-linux.zip -d /usr/local/bin &&\
    rm -f go-ios-linux.zip &&\
    ios --version

COPY usbmuxd /usr/local/bin
COPY go-ncm /usr/local/bin

COPY logger.sh /opt
COPY debug.sh /opt
COPY entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]
