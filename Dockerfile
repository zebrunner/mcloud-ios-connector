FROM alpine:3.22.1
### In case  of any build errors try to use 'FROM --platform=linux/amd64 ...'

ENV DEBIAN_FRONTEND=noninteractive \
    DEVICE_UDID='' \
    DEVICE_BUS=/dev/bus/usb/003/011 \
    POLLING_SEC=5 \
    ### Debug mode vars
    DEBUG=false \
    DEBUG_TIMEOUT=3600 \
    VERBOSE=false \
    ### Logger
    LOGGER_LEVEL=INFO \
    ### iOS envs
    WDA_HOST=localhost \
    WDA_PORT=8100 \
    MJPEG_PORT=8101 \
    WDA_WAIT_TIMEOUT=30 \
    WDA_LOG_FILE=/tmp/log/wda.log \
    WDA_BUNDLEID=com.facebook.WebDriverAgentRunner.xctrunner \
    TEST_RUNNER_BUNDLE_ID='' \
    XCTEST_CONFIG='' \
    WDA_FILE=/tmp/zebrunner/WebDriverAgent.ipa \
    ### Usbmuxd settings "host:port"
    USBMUXD_SOCKET_ADDRESS='' \
    USBMUXD_PORT=2222

RUN mkdir /opt/zebrunner/

WORKDIR /opt/zebrunner/

RUN mkdir /tmp/log/ ;\
    mkdir /tmp/zebrunner/ ;\
    ### busybox-extras include (unzip, wget, iputils-ping (ping), nc) packages
    apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing \
        bash nano jq curl socat libc6-compat busybox-extras libimobiledevice-glue libusb libimobiledevice net-tools ;\
    # apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing usbmuxd ;\
    ### Grab go-ios from github and extract it in a folder
    mkdir /tmp/go-ios/ ;\
    wget -O /tmp/go-ios/go-ios-linux.zip https://github.com/danielpaulus/go-ios/releases/download/v1.0.182/go-ios-linux.zip ;\
    unzip /tmp/go-ios/go-ios-linux.zip -d /tmp/go-ios/ ;\
    cp /tmp/go-ios/ios-amd64 /usr/local/bin/ios ;\
    rm -rf /tmp/go-ios ;\
    ios --version

COPY bin/ /usr/local/bin/
COPY util/ /opt/zebrunner/util/
COPY entrypoint.sh /opt/zebrunner/

ENTRYPOINT ["/opt/zebrunner/entrypoint.sh"]
HEALTHCHECK --interval=20s --timeout=5s --start-period=120s --start-interval=10s --retries=3 \
    CMD curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200 OK' || exit 1
