#!/usr/bin/env bash

[ "${WRQ_ACCEPTANCE_ACTIVE:-}" = "1" ] || return 0

wrq_section "doctor"

wrq_use_library "doctor"
doctor_source="$WRQ_TEST_ROOT/doctor-paper.pdf"
wrq_make_pdf "$doctor_source" "doctor"
import_output=$(wrq_run --json import "$doctor_source")
import_status=$?
wrq_expect_status "doctor fixture imports" "$import_status" 0 "$import_output" "wrq_storage.md"

output=$(wrq_run --json doctor)
status=$?
wrq_expect_status "healthy doctor succeeds" "$status" 0 "$output"
wrq_expect_json "healthy doctor validates record and asset" "$output" '
  value["checked_records"] == 1 && value["checked_assets"] == 1 &&
    value["errors"] == [] && value["warnings"] == []
' "wrq_storage.md"

stale_part="$WRQ_PATH/.wrq/tmp/abandoned.part"
printf 'partial download\n' > "$stale_part"
ruby -e 'stamp = Time.now - 7200; File.utime(stamp, stamp, ARGV.fetch(0))' "$stale_part"
output=$(wrq_run --json doctor)
status=$?
wrq_expect_status "temporary-file warning is nonfatal" "$status" 0 "$output"
wrq_expect_json "doctor reports abandoned temporary file" "$output" 'value["warnings"].any? { |warning| warning.include?("abandoned") }' "wrq_storage.md"
if [ -f "$stale_part" ]; then
  wrq_pass
else
  wrq_fail "doctor without --fix does not mutate" "temporary file remains" "$output" "wrq_storage.md"
fi

output=$(wrq_run doctor --fix --json)
status=$?
wrq_expect_status "doctor --fix succeeds for derived debris" "$status" 0 "$output"
wrq_expect_json "doctor --fix reports cleanup" "$output" 'value["removed_temporary_files"] == 1 && value["errors"] == []' "wrq_storage.md"
if [ ! -e "$stale_part" ]; then
  wrq_pass
else
  wrq_fail "doctor --fix removes abandoned temporary file" "temporary file absent" "$output" "wrq_storage.md"
fi

managed_pdf=$(find "$WRQ_PATH/library" -type f -name '*.pdf' -print | head -n 1)
printf '\ntampered\n' >> "$managed_pdf"
output=$(wrq_run --json doctor)
status=$?
wrq_expect_status "hash corruption makes doctor fail" "$status" 1 "$output"
wrq_expect_json "doctor reports hash mismatch" "$output" 'value["errors"].any? { |error| error.include?("hash mismatch") }' "wrq_storage.md"

output=$(wrq_run doctor --fix --json)
status=$?
wrq_expect_status "doctor --fix does not hide authoritative corruption" "$status" 1 "$output"
wrq_expect_json "doctor --fix preserves corruption report" "$output" 'value["errors"].any? { |error| error.include?("hash mismatch") }' "wrq_storage.md"

invalid_record="$WRQ_PATH/.wrq/records/invalid.json"
printf '{this is not json\n' > "$invalid_record"
output=$(wrq_run doctor --json)
status=$?
wrq_expect_status "invalid record makes doctor fail" "$status" 1 "$output"
wrq_expect_json "doctor reports invalid record" "$output" 'value["errors"].any? { |error| error.include?("invalid record") }' "wrq_storage.md"
