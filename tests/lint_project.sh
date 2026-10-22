#!/bin/bash
# shellcheck disable=SC2034
# The settings and the checks of the project for tests/lint.sh (CONVENTIONS.md): mcloud-ios-connector.

scripts=(entrypoint.sh util/*.sh tests/*.sh)
# the helper of the image is Go: gofmt indents it with tabs
tab_files=(Makefile tools/mcloud-ios/go.mod tools/mcloud-ios/main.go)

# project_checks: gofmt and go vet of the helper, when Go is installed (the image build compiles it anyway)
# shellcheck disable=SC2329
project_checks() {
  section "Go helper"
  if ! command -v go > /dev/null 2>&1; then
    skip_check "gofmt and go vet of tools/mcloud-ios" "go is not installed"
    return
  fi
  check "tools/mcloud-ios is formatted by gofmt" "" "$(gofmt -l tools/mcloud-ios)"
  if vet="$(cd tools/mcloud-ios && GOTOOLCHAIN=auto go vet ./... 2>&1)"; then
    pass "go vet of tools/mcloud-ios"
  else
    fail "go vet of tools/mcloud-ios" "go vet failed" "$vet"
  fi
}
