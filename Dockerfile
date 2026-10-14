FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
# In case of any build errors try to use 'FROM --platform=linux/amd64 ...'

ENV DEVICE_UDID="" \
    POLLING_SEC=5 \
    DEVICE_UNAVAILABLE_TIMEOUT=600 \
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
    TEST_RUNNER_BUNDLE_ID="" \
    XCTEST_CONFIG="" \
    WDA_FILE=/tmp/zebrunner/WebDriverAgent.ipa \
    # Usbmuxd settings "host:port"
    USBMUXD_SOCKET_ADDRESS="" \
    USBMUXD_PORT=2222

WORKDIR /opt/zebrunner/

COPY certs/ /usr/local/share/ca-certificates/

RUN mkdir -p /tmp/log /tmp/zebrunner /tmp/go-ios /opt/zebrunner/devimages && \
    # busybox-extras include (unzip, wget, iputils-ping (ping), nc) packages
    # All the packages are in the main and community repositories of the pinned release, so no edge/testing is needed
    apk add --no-cache \
        bash=5.3.9-r1 nano=9.2-r0 jq=1.8.2-r0 curl=8.22.0-r0 socat=1.8.1.3-r0 libc6-compat=1.1.0-r4 \
        busybox-extras=1.37.0-r31 libimobiledevice-glue=1.3.2-r0 libusb=1.0.30-r0 libimobiledevice=1.4.0-r0 \
        net-tools=2.10-r3 ca-certificates=20260909-r0 && \
    update-ca-certificates && \
    # Grab go-ios from github and extract it in a folder
    wget -q -O /tmp/go-ios/go-ios-linux.zip https://github.com/danielpaulus/go-ios/releases/download/v1.3.2/go-ios-linux.zip && \
    echo "a55fdb4c507391c0548252e01d1deb6ae3c7fd99cfbce842c6f80569cc125604  /tmp/go-ios/go-ios-linux.zip" > /tmp/go-ios/sha256sum.txt && \
    sha256sum -c /tmp/go-ios/sha256sum.txt && \
    unzip /tmp/go-ios/go-ios-linux.zip -d /tmp/go-ios/ && \
    cp /tmp/go-ios/ios-amd64 /usr/local/bin/ios && \
    rm -rf /tmp/go-ios && \
    ios --version

COPY bin/ /usr/local/bin/
COPY util/ /opt/zebrunner/util/
COPY entrypoint.sh /opt/zebrunner/

ARG VERSION=dev
LABEL org.opencontainers.image.title="Zebrunner MCloud iOS Connector" \
      org.opencontainers.image.description="usbmuxd and WebDriverAgent of an iOS device of Zebrunner MCloud" \
      org.opencontainers.image.source="https://github.com/zebrunner/mcloud-ios-connector" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${VERSION}"

ENTRYPOINT ["/opt/zebrunner/entrypoint.sh"]

HEALTHCHECK --interval=20s --timeout=5s --start-period=120s --start-interval=10s --retries=3 \
    CMD ["sh", "-c", "curl -Is \"http://${WDA_HOST}:${WDA_PORT}/status\" | head -1 | grep -q 200 || exit 1"]
