#!/bin/bash
# Checks of the docker image: build, contents and the entrypoint startup without a device.
# IMAGE overrides the tag of the tested image (it is built when missing, REBUILD=true builds it anyway),
# PLATFORM its platform (the image is amd64 only: go-ios is the amd64 binary).
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

IMAGE="${IMAGE:-mcloud-ios-connector:test}"
PLATFORM="${PLATFORM:-linux/amd64}"
PREFIX="mcloud-ios-connector-test-$$"

require_cmd docker
docker info > /dev/null 2>&1 || skip "requires a running docker daemon"

# cleanup: removes the startup container
# called by the EXIT trap of lib.sh
# shellcheck disable=SC2329
cleanup() {
  docker rm --force "${PREFIX}-startup" > /dev/null 2>&1
}

# in_image <command...>: runs the command in a new container of the image instead of the entrypoint
in_image() {
  docker run --rm --platform "$PLATFORM" --entrypoint "$1" "$IMAGE" "${@:2}" 2>&1
}

section "build"
if [[ "${REBUILD:-false}" != "true" ]] && docker image inspect "$IMAGE" > /dev/null 2>&1; then
  skip_check "image builds" "$IMAGE exists, REBUILD=true builds it again"
elif docker build --progress=plain --platform "$PLATFORM" --provenance=false --tag "$IMAGE" . > "${WORK}/build.log" 2>&1; then
  pass "image builds"
else
  fail "image builds" "docker build failed" "$(tail -100 "${WORK}/build.log")"
  finish
fi

section "contents"
check_contains "go-ios works" "1.3.2" "$(in_image ios --version)"
for file in /opt/zebrunner/entrypoint.sh /opt/zebrunner/util/logger.sh /opt/zebrunner/util/debug.sh /usr/local/bin/usbmuxd /usr/local/bin/go-ncm; do
  if in_image test -x "$file" > /dev/null; then
    pass "${file} is executable"
  else
    fail "${file} is executable" "not executable" "$(in_image ls -l "$file")"
  fi
done
for tool in bash curl jq nc socat usbmuxd; do
  if in_image sh -c "command -v ${tool}" > /dev/null; then
    pass "${tool} is installed"
  else
    fail "${tool} is installed" "${tool} is missing" ""
  fi
done
check_contains "Apple root certificate is trusted" "apple-root-ca" "$(in_image ls /usr/local/share/ca-certificates)"

section "pinned versions"
# the packages of the 'apk add' command are name=version
installed="$(in_image apk list --installed)"
packages="$(sed -n '/^    apk add --no-cache \\$/,/&& \\$/p' Dockerfile | grep -oE '[a-z0-9][a-z0-9.+_-]*=[^ \\]+')"
for package in $packages; do
  name="${package%%=*}"
  version="${package#*=}"
  # libc6-compat is a provider name of gcompat, its version is the version of the provider
  if [[ "$name" == libc6-compat ]]; then
    check_contains "${name} ${version} is installed" "gcompat-${version}" "$installed"
  else
    check_contains "${name} ${version} is installed" "${name}-${version} " "$installed"
  fi
done

section "configuration"
config="$(docker image inspect "$IMAGE" --format '{{json .Config}}')"
check_contains "entrypoint" '"Entrypoint":["/opt/zebrunner/entrypoint.sh"]' "$config"
# the literal text of the image configuration
# shellcheck disable=SC2016
check_contains "healthcheck checks WDA status" 'WDA_HOST}:${WDA_PORT}/status' "$config"
for env in POLLING_SEC=5 DEVICE_UNAVAILABLE_TIMEOUT=600 LOGGER_LEVEL=INFO WDA_PORT=8100 MJPEG_PORT=8101 USBMUXD_PORT=2222 WDA_WAIT_TIMEOUT=30 DEBUG=false; do
  check_contains "default ${env}" "\"${env}\"" "$config"
done

section "startup"
docker run --detach --name "${PREFIX}-startup" --platform "$PLATFORM" --env DEVICE_UDID=00000000-TEST \
  --env USBMUXD_SOCKET_ADDRESS=127.0.0.1:1 "$IMAGE" > /dev/null
# the unreachable usbmuxd socket is retried 10 times, then the entrypoint exits
docker wait "${PREFIX}-startup" > "${WORK}/exit-code"
logs="$(docker logs "${PREFIX}-startup" 2>&1)"
check_contains "banner" "MCLOUD-IOS-CONNECTOR" "$logs"
check_contains "unreachable usbmuxd is reported" "Usbmuxd socket is not available. Exiting!" "$logs"
check "unreachable usbmuxd exits with 0" "0" "$(cat "${WORK}/exit-code")"

section "configuration validation"
validation="$(docker run --rm --platform "$PLATFORM" --env DEVICE_UDID= "$IMAGE" 2>&1)"
check_contains "empty DEVICE_UDID is reported" "DEVICE_UDID is required" "$validation"
check_contains "invalid configuration ends the entrypoint" "Invalid configuration. Exiting!" "$validation"
validation="$(docker run --rm --platform "$PLATFORM" --env DEVICE_UDID=00000000-TEST --env WDA_PORT=abc "$IMAGE" 2>&1)"
check_contains "invalid WDA_PORT is reported" "WDA_PORT must be a non-negative integer, but it is 'abc'." "$validation"
validation="$(docker run --rm --platform "$PLATFORM" --env DEVICE_UDID=00000000-TEST --env HOST_OS=windows "$IMAGE" 2>&1)"
check_contains "invalid HOST_OS is reported" "HOST_OS must be LINUX, DARWIN or MACOS, but it is 'windows'." "$validation"

finish
