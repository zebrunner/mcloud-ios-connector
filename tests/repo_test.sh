#!/bin/bash
# Static checks of the repository files, no docker: the pinned versions of the Dockerfile and the Dependabot configuration.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

# apk_packages: the arguments of the 'apk add' command of the Dockerfile, one per line
apk_packages() {
  sed -n '/^    apk add --no-cache/,/&& \\$/p' Dockerfile | sed -e 's/^ *apk add --no-cache//' -e 's/&& *\\$//' -e 's/\\$//' |
    tr -s ' ' '\n' | grep -v '^$'
}

section "Dockerfile pins"
from="$(grep '^FROM ' Dockerfile)"
if [[ "$from" =~ ^FROM\ alpine:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]; then
  pass "base image is alpine:<version>@sha256:<digest>"
else
  fail "base image is alpine:<version>@sha256:<digest>" "unexpected FROM" "$from"
fi
check_not_contains "no edge repository of Alpine" "alpine/edge" "$(grep -v '^ *#' Dockerfile)"
check_not_contains "no unpinned latest tag" ":latest" "$(grep -v '^ *#' Dockerfile)"

packages="$(apk_packages)"
check "the apk add command is found" "true" "$([[ -n "$packages" ]] && echo true || echo false)"
unpinned="$(grep -vE '^[a-z0-9][a-z0-9.+_-]*=[0-9][^ =]*-r[0-9]+$' <<< "$packages" || true)"
check "every apk package is pinned as name=version-rN" "" "$unpinned"

sums="$(grep -cE '^ *echo "[0-9a-f]{64}  [^"]+" > ' Dockerfile || true)"
check "the downloaded go-ios archive has a sha256 checksum" "1" "$sums"
check_contains "the checksum is checked" "sha256sum -c" "$(cat Dockerfile)"

section "Dependabot"
config=".github/dependabot.yml"
# the linters of tests/requirements-lint.txt are updated in mcloud-conventions
for ecosystem in github-actions docker; do
  check_contains "${ecosystem} is updated" "package-ecosystem: ${ecosystem}" "$(cat "$config")"
done
check "tests/requirements-lint.txt exists" "true" "$([[ -f tests/requirements-lint.txt ]] && echo true || echo false)"
# the pinned linters: name==version
unpinned="$(grep -vE '^(#|$)' tests/requirements-lint.txt | grep -vE '^[A-Za-z0-9._-]+==[0-9][A-Za-z0-9.]*$' || true)"
check "every linter is pinned as name==version" "" "$unpinned"

finish
