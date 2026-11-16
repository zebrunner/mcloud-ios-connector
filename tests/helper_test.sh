#!/bin/bash
# Tests of the Go helper tools/mcloud-ios (go test): its usbmuxd requests against a fake usbmuxd, no device.
source "$(dirname "$0")/lib.sh"
cd "${REPO}/tools/mcloud-ios" || exit 1

require_cmd go

section "Go helper"
if output="$(GOTOOLCHAIN=auto go test ./... 2>&1)"; then
  pass "go test of tools/mcloud-ios"
else
  fail "go test of tools/mcloud-ios" "go test failed" "$output"
fi

finish
