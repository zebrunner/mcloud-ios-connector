#!/bin/bash
# Static checks of the project files, every linter run is a check (also in JUnit XML with JUNIT_DIR);
# the tools: pip install -r tests/requirements-lint.txt
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

# lint <description> <command...>: runs a linter as a check, its output is shown when it fails
lint() {
  local output
  output="$("${@:2}" 2>&1)"
  local status=$?
  if [[ "$status" -eq 0 ]]; then
    pass "$1"
  else
    fail "$1" "exit status ${status}" "$output"
  fi
}

missing=""
for tool in actionlint hadolint pymarkdown shellcheck shfmt yamllint; do
  command -v "$tool" > /dev/null 2>&1 || missing="${missing} ${tool}"
done
if [[ -n "$missing" ]]; then
  fail "lint tools are installed" "missing:${missing}" \
    "missing tools:${missing} (pip install -r tests/requirements-lint.txt, hadolint on macOS: brew install hadolint)"
  finish
fi

section "yaml"
lint "yamllint" yamllint --strict .

section "GitHub workflows"
lint "actionlint" actionlint

section "Dockerfile"
lint "hadolint" hadolint Dockerfile

section "markdown"
lint "pymarkdown" pymarkdown scan README.md

section "shell"
scripts=(entrypoint.sh util/*.sh tests/*.sh)
for script in "${scripts[@]}"; do
  lint "bash -n ${script}" bash -n "$script"
done
lint "shellcheck" shellcheck --severity=warning "${scripts[@]}"
# style of .editorconfig
lint "shfmt" shfmt -d "${scripts[@]}"

[[ "$FAILED" -eq 0 ]] && echo "lint: ok"
finish
