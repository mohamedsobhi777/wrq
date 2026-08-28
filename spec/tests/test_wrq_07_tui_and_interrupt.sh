#!/usr/bin/env bash

[ "${WRQ_ACCEPTANCE_ACTIVE:-}" = "1" ] || return 0

wrq_section "tui-errors"

wrq_use_library "tui-nontty"
stdout_file="$WRQ_TEST_ROOT/tui.stdout"
stderr_file="$WRQ_TEST_ROOT/tui.stderr"
"$WRQ_BIN_PATH" search >"$stdout_file" 2>"$stderr_file"
status=$?
stdout_value=$(cat "$stdout_file")
stderr_value=$(cat "$stderr_file")
wrq_expect_status "TUI refuses non-interactive input" "$status" 1 "$stdout_value$stderr_value"
wrq_expect_contains "TUI non-interactive diagnostic" "$stderr_value" "requires an interactive terminal"
if [ ! -s "$stdout_file" ]; then
  wrq_pass
else
  wrq_fail "TUI diagnostics stay off stdout" "empty stdout" "$stdout_value" "wrq_command_line.md"
fi

wrq_use_library "interrupted-download"
: > "$WRQ_FIXTURE_REQUEST_LOG"
saved_pdf_url="$WRQ_ARXIV_PDF_URL"
export WRQ_ARXIV_PDF_URL="$WRQ_FIXTURE_BASE_URL/slow-pdf"
interrupt_output="$WRQ_TEST_ROOT/interrupted-download.out"
# Non-interactive shells normally start asynchronous children with SIGINT
# ignored. Reset it from a synchronous launcher immediately before exec so the
# target receives the same Interrupt as an interactive Ctrl-C.
ruby -e 'Signal.trap("INT", "DEFAULT"); exec(*ARGV)' \
  "$WRQ_BIN_PATH" add 1706.03762 --no-open >"$interrupt_output" 2>&1 &
download_pid=$!

attempts=0
while ! grep -q '/slow-pdf/' "$WRQ_FIXTURE_REQUEST_LOG" 2>/dev/null && [ "$attempts" -lt 100 ]; do
  if ! kill -0 "$download_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
  attempts=$((attempts + 1))
done

if kill -0 "$download_pid" 2>/dev/null; then
  kill -INT "$download_pid" 2>/dev/null
fi
wait "$download_pid"
status=$?
export WRQ_ARXIV_PDF_URL="$saved_pdf_url"
output=$(cat "$interrupt_output")
wrq_expect_status "interrupted download returns cancelled status" "$status" 1 "$output" "wrq_storage.md"
wrq_expect_contains "interrupted download reports cancellation" "$output" "Cancelled." "wrq_command_line.md"
if [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 0 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/records" '*.json')" -eq 0 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/tmp" '*')" -eq 0 ]; then
  wrq_pass
else
  wrq_fail "interrupted download leaves no partial state" "no PDF, record, or temporary file" "$output" "wrq_storage.md"
fi
