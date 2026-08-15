FROM alpine:3.24.1
### In case  of any build errors try to use 'FROM --platform=linux/amd64 ...'

ENV DEVICE_UDID='' \
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

WORKDIR /opt/zebrunner/

COPY certs/ /usr/local/share/ca-certificates/

RUN mkdir -p /tmp/log /tmp/zebrunner /tmp/go-ios /opt/zebrunner/devimages && \
    ### busybox-extras include (unzip, wget, iputils-ping (ping), nc) packages
    apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing \
        bash nano jq curl socat libc6-compat busybox-extras libimobiledevice-glue libusb libimobiledevice net-tools ca-certificates ;\
    update-ca-certificates ;\
#    ### pymobiledevice related packages
#    apk add --no-cache python3 py3-pip gcc python3-dev musl-dev linux-headers ;\
#    python3 -m venv venv ;\
#    source venv/bin/activate ;\
#    pip install pymobiledevice3==10.7.4 ;\
#    pymobiledevice3 version ;\
#    deactivate ;\
    ### usbmuxd related packages
    # apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing usbmuxd ;\
    ### Grab go-ios from github and extract it in a folder
    mkdir /tmp/go-ios/ ;\
    wget -O /tmp/go-ios/go-ios-linux.zip https://github.com/danielpaulus/go-ios/releases/download/v1.3.2/go-ios-linux.zip ;\
    unzip /tmp/go-ios/go-ios-linux.zip -d /tmp/go-ios/ ;\
    cp /tmp/go-ios/ios-amd64 /usr/local/bin/ios ;\
    rm -rf /tmp/go-ios ;\
    ios --version

COPY bin/ /usr/local/bin/
COPY util/ /opt/zebrunner/util/
COPY entrypoint.sh /opt/zebrunner/

ENTRYPOINT ["/opt/zebrunner/entrypoint.sh"]
HEALTHCHECK --interval=20s --timeout=5s --start-period=120s --start-interval=10s --retries=3 \
    CMD curl -Is "http://${WDA_HOST}:${WDA_PORT}/status" | head -1 | grep -q '200' || exit 1
