# check=skip=SecretsUsedInArgOrEnv
# HOST_SSH_KEY is the path of the mounted ssh key of the macOS host, not a secret itself
# The helper of the connector (tools/mcloud-ios): the lockdown and usbmuxd requests the go-ios CLI does not have.
# The stage runs on the platform of the builder, the binary is static (no cgo) for the target platform (amd64 or arm64)
FROM --platform=${BUILDPLATFORM} golang:1.27.2-alpine@sha256:f92b6ef800e499660581efdabdf25d9d817a9d124eaf900924f0504e7e27e12d AS helper

ARG TARGETARCH
WORKDIR /src
COPY tools/mcloud-ios/ ./
RUN env CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} GOTOOLCHAIN=local go build -trimpath -ldflags="-s -w" -o /out/mcloud-ios .

# netmuxd: the usbmuxd of the network (Wi-Fi) devices on Linux, built for musl: the release binaries need glibc 2.38.
# Cargo.lock of the release pins the crates
FROM rust:1.99.1-alpine3.24@sha256:b1d5dd5a22a09404d3e798c0cf051b689077360374eb505fa5bb93c479693d87 AS netmuxd

WORKDIR /src
RUN apk add --no-cache \
        musl-dev=1.2.6-r3 cmake=4.2.3-r0 make=4.4.1-r4 perl=5.42.2-r1 git=2.54.0-r0 linux-headers=7.0.0-r1 && \
    wget -q -O /tmp/netmuxd.tar.gz https://github.com/jkcoxson/netmuxd/archive/refs/tags/v0.4.3.tar.gz && \
    echo "0fe1ee362d725f0275a47618eb2ec811c93e1122761b6312bf45a6a60444fdb1  /tmp/netmuxd.tar.gz" > /tmp/netmuxd.sha256 && \
    sha256sum -c /tmp/netmuxd.sha256 && \
    tar -xzf /tmp/netmuxd.tar.gz --strip-components 1 && \
    cargo build --release --locked --no-default-features --bin netmuxd && \
    strip target/release/netmuxd && \
    mkdir -p /out && cp target/release/netmuxd /out/

# usbmuxd: the usbmuxd of the USB devices, the commit 2efa75a of libimobiledevice/usbmuxd (1.1.1-71-g2efa75a: the release
# 1.1.1 of 2020 misses the support of the recent iOS versions), built against the libimobiledevice libraries of the image
FROM alpine:3.24.3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS usbmuxd

WORKDIR /src
RUN apk add --no-cache \
        build-base=0.5-r4 autoconf=2.73-r0 automake=1.18.1-r1 libtool=2.6.0-r1 pkgconf=2.5.1-r0 libusb-dev=1.0.30-r0 \
        libplist-dev=2.7.0-r1 libimobiledevice-dev=1.4.0-r0 libimobiledevice-glue-dev=1.3.2-r0 && \
    wget -q -O /tmp/usbmuxd.tar.gz https://github.com/libimobiledevice/usbmuxd/archive/2efa75a0a9ca73f2a5b6ec71e5ae6cb43cdab580.tar.gz && \
    echo "23636e3ce3d24ddb0e7ff790710a95fa7354b6ee33c3b53dc10ddcabc099e67f  /tmp/usbmuxd.tar.gz" > /tmp/usbmuxd.sha256 && \
    sha256sum -c /tmp/usbmuxd.sha256 && \
    tar -xzf /tmp/usbmuxd.tar.gz --strip-components 1 && \
    # the version of a git checkout: the archive has no .git
    printf '1.1.1-71-g2efa75a' > .tarball-version && \
    ./autogen.sh --prefix=/usr --without-systemd && \
    make -j"$(nproc)" && \
    strip src/usbmuxd && \
    mkdir -p /out && cp src/usbmuxd /out/ && \
    /out/usbmuxd --version

# go-ncm: the CDC-NCM network driver of go-ios (cmd/cdc-ncm) for the USB devices of iOS 17+, from the sources of the go-ios
# release of the image (go.sum pins the modules); cgo for libusb
FROM golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS ncm

WORKDIR /src
RUN apk add --no-cache \
        build-base=0.5-r4 pkgconf=2.5.1-r0 libusb-dev=1.0.30-r0 && \
    wget -q -O /tmp/go-ios.tar.gz https://github.com/danielpaulus/go-ios/archive/refs/tags/v1.3.2.tar.gz && \
    echo "ee5283359650cd7040f785d0eb8c6376b09bca3255cb20bcbfc4e8769f4a25bb  /tmp/go-ios.tar.gz" > /tmp/go-ios.sha256 && \
    sha256sum -c /tmp/go-ios.sha256 && \
    tar -xzf /tmp/go-ios.tar.gz --strip-components 1 && \
    env CGO_ENABLED=1 GOTOOLCHAIN=local go build -trimpath -ldflags="-s -w" -o /out/go-ncm ./cmd/cdc-ncm

FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

# the platform of the image (amd64 or arm64): the go-ios binary of the release
ARG TARGETARCH

ENV DEVICE_UDID="" \
    DEVICE_CONNECTION=usb \
    DEVICE_ADDRESS="" \
    DEVICE_WDA_PORT="" \
    DEVICE_MJPEG_PORT="" \
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
    USBMUXD_PORT=2222 \
    # Simulators: the macOS host over ssh
    HOST_SSH_USER="" \
    HOST_SSH_HOST=host.docker.internal \
    HOST_SSH_PORT=22 \
    HOST_SSH_KEY=/opt/zebrunner/ssh/id_ed25519 \
    HOST_SSH_PROXY_PORT=22

WORKDIR /opt/zebrunner/

COPY certs/ /usr/local/share/ca-certificates/

RUN mkdir -p /tmp/log /tmp/zebrunner /tmp/go-ios /opt/zebrunner/devimages && \
    # busybox-extras include (unzip, wget, iputils-ping (ping), nc) packages
    # All the packages are in the main and community repositories of the pinned release, so no edge/testing is needed
    apk add --no-cache \
        bash=5.3.9-r1 nano=9.3-r0 jq=1.8.2-r0 curl=8.23.0-r0 socat=1.8.1.3-r0 libc6-compat=1.1.0-r4 \
        busybox-extras=1.37.0-r31 libimobiledevice-glue=1.3.2-r0 libusb=1.0.30-r0 libimobiledevice=1.4.0-r0 \
        net-tools=2.10-r3 ca-certificates=20261020-r0 openssh-client-default=10.3_p1-r1 && \
    update-ca-certificates && \
    # Grab go-ios from github and extract it in a folder
    wget -q -O /tmp/go-ios/go-ios-linux.zip https://github.com/danielpaulus/go-ios/releases/download/v1.3.2/go-ios-linux.zip && \
    echo "a55fdb4c507391c0548252e01d1deb6ae3c7fd99cfbce842c6f80569cc125604  /tmp/go-ios/go-ios-linux.zip" > /tmp/go-ios/sha256sum.txt && \
    sha256sum -c /tmp/go-ios/sha256sum.txt && \
    unzip /tmp/go-ios/go-ios-linux.zip -d /tmp/go-ios/ && \
    cp "/tmp/go-ios/ios-${TARGETARCH:-amd64}" /usr/local/bin/ios && \
    rm -rf /tmp/go-ios && \
    ios --version

COPY --from=helper /out/mcloud-ios /usr/local/bin/
COPY --from=netmuxd /out/netmuxd /usr/local/bin/
COPY --from=usbmuxd /out/usbmuxd /usr/local/bin/
COPY --from=ncm /out/go-ncm /usr/local/bin/
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
    CMD ["sh", "-c", "curl -s -o /dev/null -w '%{http_code}' --max-time 4 \"http://${WDA_HOST}:${WDA_PORT}/status\" | grep -q 200 || exit 1"]
