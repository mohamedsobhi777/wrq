#!/usr/bin/env bash

[ "${WRQ_ACCEPTANCE_ACTIVE:-}" = "1" ] || return 0

wrq_section "import"

wrq_use_library "import-copy"
source_dir="$WRQ_TEST_ROOT/import-copy-source"
source_pdf="$source_dir/Graph Paper.PDF"
wrq_make_pdf "$source_pdf" "copy"
output=$(wrq_run --json import "$source_pdf")
status=$?
wrq_expect_status "copy import succeeds" "$status" 0 "$output" "wrq_storage.md"
wrq_expect_json "copy import returns one result" "$output" 'value.is_a?(Array) && value.length == 1 && value[0]["deduplicated"] == false' "wrq_storage.md"
if [ -f "$source_pdf" ] && [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 1 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/records" '*.json')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "copy import preserves source and catalogs one asset" "source, PDF, and record all present" "$output" "wrq_storage.md"
fi

wrq_use_library "import-move"
move_pdf="$WRQ_TEST_ROOT/import-move-source/move-me.pdf"
wrq_make_pdf "$move_pdf" "move"
output=$(wrq_run import --move "$move_pdf")
status=$?
wrq_expect_status "move import succeeds" "$status" 0 "$output" "wrq_storage.md"
if [ ! -e "$move_pdf" ] && [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "--move removes source after cataloging" "source absent and managed PDF present" "$output" "wrq_storage.md"
fi

directory_source="$WRQ_TEST_ROOT/import-directory-source"
top_pdf="$directory_source/top-level.pdf"
nested_pdf="$directory_source/nested/nested-paper.pdf"
wrq_make_pdf "$top_pdf" "top"
wrq_make_pdf "$nested_pdf" "nested"

wrq_use_library "import-nonrecursive"
output=$(wrq_run --json import "$directory_source")
status=$?
wrq_expect_status "directory import succeeds" "$status" 0 "$output" "wrq_command_line.md"
wrq_expect_json "directory import is non-recursive by default" "$output" 'value.is_a?(Array) && value.length == 1' "wrq_command_line.md"

wrq_use_library "import-recursive"
output=$(wrq_run import "$directory_source" --recursive --json)
status=$?
wrq_expect_status "recursive directory import succeeds" "$status" 0 "$output" "wrq_command_line.md"
wrq_expect_json "--recursive visits nested PDFs" "$output" 'value.is_a?(Array) && value.length == 2' "wrq_command_line.md"
if [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 2 ]; then
  wrq_pass
else
  wrq_fail "recursive import stores both distinct assets" "two managed PDFs" "$output" "wrq_storage.md"
fi

wrq_use_library "import-invalid-extension"
invalid_text="$WRQ_TEST_ROOT/import-invalid.txt"
cp "$WRQ_FIXTURE_DIR/not_a_pdf.txt" "$invalid_text"
output=$(wrq_run import "$invalid_text")
status=$?
wrq_expect_status "non-PDF extension is rejected" "$status" 1 "$output" "wrq_command_line.md"
wrq_expect_contains "non-PDF extension diagnostic" "$output" "not a PDF file" "wrq_command_line.md"

wrq_use_library "import-invalid-content"
invalid_pdf="$WRQ_TEST_ROOT/import-invalid-content.pdf"
cp "$WRQ_FIXTURE_DIR/not_a_pdf.txt" "$invalid_pdf"
output=$(wrq_run import --move "$invalid_pdf")
status=$?
wrq_expect_status "invalid PDF bytes are rejected" "$status" 1 "$output" "wrq_storage.md"
wrq_expect_contains "invalid PDF bytes diagnostic" "$output" "not a PDF" "wrq_storage.md"
if [ -f "$invalid_pdf" ] && [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 0 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/records" '*.json')" -eq 0 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/tmp" '*')" -eq 0 ]; then
  wrq_pass
else
  wrq_fail "failed move import is transactional" "source preserved; no asset, record, or temporary file" "$output" "wrq_storage.md"
fi

wrq_use_library "import-hash-dedup"
first_pdf="$WRQ_TEST_ROOT/dedup-first.pdf"
second_pdf="$WRQ_TEST_ROOT/dedup-second.pdf"
wrq_make_pdf "$first_pdf" "same-bytes"
cp "$first_pdf" "$second_pdf"
first_output=$(wrq_run --json import "$first_pdf")
first_status=$?
second_output=$(wrq_run --json import --move "$second_pdf")
second_status=$?
wrq_expect_status "first hash import succeeds" "$first_status" 0 "$first_output" "wrq_storage.md"
wrq_expect_status "duplicate hash import succeeds" "$second_status" 0 "$second_output" "wrq_storage.md"
wrq_expect_json "duplicate hash import is identified" "$second_output" 'value.length == 1 && value[0]["deduplicated"] == true' "wrq_storage.md"
if [ ! -e "$second_pdf" ] && [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 1 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/records" '*.json')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "hash dedup creates no second record or asset" "one managed PDF and one record" "$second_output" "wrq_storage.md"
fi

wrq_use_library "import-same-basename"
same_a="$WRQ_TEST_ROOT/same-a/paper.pdf"
same_b="$WRQ_TEST_ROOT/same-b/paper.pdf"
wrq_make_pdf "$same_a" "same-name-a"
wrq_make_pdf "$same_b" "same-name-b"
output=$(wrq_run --json import "$same_a" "$same_b")
status=$?
wrq_expect_status "distinct same-basename imports succeed" "$status" 0 "$output" "wrq_storage.md"
output=$(wrq_run --json doctor)
status=$?
wrq_expect_status "same-basename imports leave a healthy catalog" "$status" 0 "$output" "wrq_storage.md"
wrq_expect_json "same basenames do not become conflicting aliases" "$output" 'value["errors"] == [] && value["checked_records"] == 2' "wrq_storage.md"
