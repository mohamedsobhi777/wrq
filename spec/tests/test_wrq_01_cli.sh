#!/usr/bin/env bash

[ "${WRQ_ACCEPTANCE_ACTIVE:-}" = "1" ] || return 0

wrq_section "cli"

wrq_use_library "cli-help"
output_file="$WRQ_TEST_ROOT/help.stdout"
error_file="$WRQ_TEST_ROOT/help.stderr"
"$WRQ_BIN_PATH" --help >"$output_file" 2>"$error_file"
status=$?
output=$(cat "$output_file")
errors=$(cat "$error_file")
wrq_expect_status "--help succeeds" "$status" 0 "$output$errors"
wrq_expect_contains "--help identifies wrq" "$output" "local-first research paper library"
if [ ! -e "$WRQ_PATH" ] && [ ! -s "$error_file" ]; then
  wrq_pass
else
  wrq_fail "--help has no filesystem or stderr side effects" "no library and empty stderr" "$output$errors" "wrq_command_line.md"
fi

output=$(wrq_run -h)
status=$?
wrq_expect_status "-h succeeds" "$status" 0 "$output"
wrq_expect_contains "-h shows usage" "$output" "Usage:"

output=$(wrq_run --version)
status=$?
wrq_expect_status "--version succeeds" "$status" 0 "$output"
wrq_expect_matches "--version format" "$output" '^wrq [0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$'

output=$(wrq_run -v)
status=$?
wrq_expect_status "-v succeeds" "$status" 0 "$output"
wrq_expect_matches "-v format" "$output" '^wrq [0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$'

output=$(wrq_run --path)
status=$?
wrq_expect_status "missing --path value is usage error" "$status" 2 "$output"
wrq_expect_contains "usage errors explain recovery" "$output" "Run 'wrq --help' for usage."

output=$(wrq_run import)
status=$?
wrq_expect_status "missing import operand is usage error" "$status" 2 "$output"

output=$(wrq_run info)
status=$?
wrq_expect_status "missing info selector is usage error" "$status" 2 "$output"

output=$(wrq_run add)
status=$?
wrq_expect_status "missing add reference is usage error" "$status" 2 "$output"

output=$(wrq_run update)
status=$?
wrq_expect_status "missing update selector is usage error" "$status" 2 "$output"

output=$(wrq_run remove " " --yes)
status=$?
wrq_expect_status "blank selector is a usage error" "$status" 2 "$output"

output=$(wrq_run --print-path open definitely-not-present)
status=$?
wrq_expect_status "missing local paper is operational failure" "$status" 1 "$output"
wrq_expect_contains "missing local paper has diagnostic" "$output" "no paper matches"

source_dir="$WRQ_TEST_ROOT/cli sources"
mkdir -p "$source_dir"
source_pdf="$source_dir/path precedence paper.pdf"
wrq_make_pdf "$source_pdf" "path-precedence"
environment_root="$WRQ_TEST_ROOT/path-from-environment"
override_root="$WRQ_TEST_ROOT/path from option"
export WRQ_PATH="$environment_root"
output=$(wrq_run import "$source_pdf" --path "$override_root" --json)
status=$?
wrq_expect_status "--path override import succeeds" "$status" 0 "$output"
if [ "$(wrq_file_count "$override_root/library" '*.pdf')" -eq 1 ] && [ ! -e "$environment_root" ]; then
  wrq_pass
else
  wrq_fail "--path overrides WRQ_PATH" "one PDF only under the option path" "$output" "wrq_command_line.md"
fi

equal_root="$WRQ_TEST_ROOT/path-equals-option"
second_pdf="$source_dir/equals syntax.pdf"
wrq_make_pdf "$second_pdf" "equals-syntax"
output=$(wrq_run --path="$equal_root" --json import "$second_pdf")
status=$?
wrq_expect_status "--path=PATH syntax succeeds" "$status" 0 "$output"
if [ "$(wrq_file_count "$equal_root/library" '*.pdf')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "--path=PATH selects its root" "one PDF under the selected root" "$output" "wrq_command_line.md"
fi

default_home="$WRQ_TEST_ROOT/default-home"
mkdir -p "$default_home"
default_source="$source_dir/default root.pdf"
wrq_make_pdf "$default_source" "default-root"
output=$(env -u WRQ_PATH HOME="$default_home" NO_COLOR=1 WRQ_TEST_OPEN_LOG="$WRQ_TEST_ROOT/default-open.log" \
  "$WRQ_BIN_PATH" --json import "$default_source" 2>&1)
status=$?
wrq_expect_status "default-root import succeeds" "$status" 0 "$output"
if [ "$(wrq_file_count "$default_home/papers/library" '*.pdf')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "default root is HOME/papers" "one PDF in the isolated default root" "$output" "wrq_command_line.md"
fi
