#!/usr/bin/env bash

[ "${WRQ_ACCEPTANCE_ACTIVE:-}" = "1" ] || return 0

wrq_section "dedupe-remove"

wrq_use_library "dedupe-report"
first_dir="$WRQ_TEST_ROOT/dedupe-a"
second_dir="$WRQ_TEST_ROOT/dedupe-b"
first_pdf="$first_dir/Same-Research-Title.pdf"
second_pdf="$second_dir/Same-Research-Title.pdf"
external_copy="$WRQ_TEST_ROOT/external-copy.pdf"
wrq_make_pdf "$first_pdf" "first-content"
wrq_make_pdf "$second_pdf" "second-content"
cp "$first_pdf" "$external_copy"

output=$(wrq_run --json import "$first_pdf" "$second_pdf")
status=$?
wrq_expect_status "probable-duplicate fixtures import" "$status" 0 "$output" "wrq_storage.md"

before_external_hash=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$external_copy")
before_library_count=$(wrq_file_count "$WRQ_PATH/library" '*.pdf')
output=$(wrq_run --json dedupe "$external_copy")
status=$?
wrq_expect_status "JSON dedupe report succeeds" "$status" 0 "$output"
wrq_expect_json "dedupe identifies external exact duplicate" "$output" '
  rows = value["external_files"]
  rows.length == 1 && !rows[0]["duplicate_of"].to_s.empty? && File.file?(rows[0]["library_path"])
' "wrq_storage.md"
wrq_expect_json "dedupe reports probable title group" "$output" '
  value["probable_title_groups"].values.any? { |keys| keys.uniq.length == 2 }
' "wrq_storage.md"
wrq_expect_json "dedupe declares that nothing was deleted" "$output" 'value["deleted"] == []' "wrq_storage.md"

after_external_hash=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$external_copy")
after_library_count=$(wrq_file_count "$WRQ_PATH/library" '*.pdf')
if [ -f "$external_copy" ] && [ "$before_external_hash" = "$after_external_hash" ] && [ "$before_library_count" = "$after_library_count" ]; then
  wrq_pass
else
  wrq_fail "dedupe never modifies or deletes files" "unchanged external hash and library file count" "$output" "wrq_storage.md"
fi

output=$(wrq_run dedupe "$external_copy")
status=$?
wrq_expect_status "plain dedupe report succeeds" "$status" 0 "$output"
wrq_expect_contains "plain dedupe states safety behavior" "$output" "No files were deleted."

wrq_use_library "dedupe-rehash"
rehash_first="$WRQ_TEST_ROOT/2401.01234v1-First.pdf"
rehash_second="$WRQ_TEST_ROOT/2402.12345v1-Second.pdf"
rehash_external="$WRQ_TEST_ROOT/rehash-external.pdf"
rehash_replacement="$WRQ_TEST_ROOT/rehash-replacement.pdf"
wrq_make_pdf "$rehash_first" "rehash-shared-bytes"
cp "$rehash_first" "$rehash_second"
cp "$rehash_first" "$rehash_external"
first_output=$(wrq_run --json import "$rehash_first")
first_status=$?
second_output=$(wrq_run --json import "$rehash_second")
second_status=$?
wrq_expect_status "first rehash fixture imports" "$first_status" 0 "$first_output" "wrq_storage.md"
wrq_expect_status "second rehash fixture imports" "$second_status" 0 "$second_output" "wrq_storage.md"
first_managed=$(printf '%s' "$first_output" | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch(0).fetch("path")')
wrq_make_pdf "$rehash_replacement" "changed-after-cataloging"
mv "$rehash_replacement" "$first_managed"

output=$(wrq_run --json dedupe "$rehash_external")
status=$?
wrq_expect_status "dedupe rehashes current managed bytes" "$status" 0 "$output" "wrq_storage.md"
wrq_expect_json "stale recorded hash is excluded from exact groups and external lookup" "$output" '
  value["exact_hash_groups"] == {} &&
    value.dig("external_files", 0, "duplicate_of") == "arxiv:2402.12345" &&
    value.dig("external_files", 0, "library_path").to_s.include?("2402.12345")
' "wrq_storage.md"

wrq_use_library "remove-confirmation"
remove_source="$WRQ_TEST_ROOT/remove-this-paper.pdf"
wrq_make_pdf "$remove_source" "remove"
import_output=$(wrq_run --json import "$remove_source")
import_status=$?
wrq_expect_status "remove fixture imports" "$import_status" 0 "$import_output" "wrq_storage.md"

output=$(printf 'NO\n' | wrq_run remove "remove this paper")
status=$?
wrq_expect_status "remove cancellation is failure/cancel status" "$status" 1 "$output"
wrq_expect_contains "remove cancellation is explicit" "$output" "Cancelled."
if [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 1 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/records" '*.json')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "cancelled removal preserves paper" "managed PDF and record remain" "$output" "wrq_storage.md"
fi

output=$(printf 'YES\n' | wrq_run remove "remove this paper")
status=$?
wrq_expect_status "confirmed removal succeeds" "$status" 0 "$output"
wrq_expect_contains "confirmed removal reports trash" "$output" ".wrq/trash/"
trash_record=$(find "$WRQ_PATH/.wrq/trash" -type f -name record.json -print | head -n 1)
trash_pdf=$(find "$WRQ_PATH/.wrq/trash" -type f -name '*.pdf' -print | head -n 1)
if [ -f "$trash_record" ] && [ -f "$trash_pdf" ] && [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 0 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/records" '*.json')" -eq 0 ]; then
  wrq_pass
else
  wrq_fail "confirmed removal is recoverable" "record and PDF in trash; active catalog empty" "$output" "wrq_storage.md"
fi

wrq_use_library "remove-yes-flag"
yes_source="$WRQ_TEST_ROOT/remove-with-yes.pdf"
wrq_make_pdf "$yes_source" "remove-yes"
wrq_run --json import "$yes_source" >/dev/null
output=$(wrq_run --json remove --yes "remove with yes")
status=$?
wrq_expect_status "--yes removal succeeds without stdin" "$status" 0 "$output"
wrq_expect_json "--yes removal returns recoverable location" "$output" '
  value["key"].start_with?("sha256:") && value["trash_path"].include?("/.wrq/trash/") &&
    value["files"].any? { |path| path.end_with?("record.json") } &&
    value["files"].any? { |path| path.end_with?(".pdf") }
' "wrq_storage.md"
