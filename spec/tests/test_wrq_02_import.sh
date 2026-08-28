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

wrq_use_library "import-corrupt-hash-repair"
repair_original="$WRQ_TEST_ROOT/repair-original.pdf"
repair_move_source="$WRQ_TEST_ROOT/repair-move-source.pdf"
wrq_make_pdf "$repair_original" "repair-authoritative-bytes"
repair_output=$(wrq_run --json import "$repair_original")
repair_status=$?
wrq_expect_status "asset-repair fixture imports" "$repair_status" 0 "$repair_output" "wrq_storage.md"
managed_repair_path=$(printf '%s' "$repair_output" | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch(0).fetch("path")')
expected_repair_hash=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$repair_original")
printf '\ncorrupt managed bytes\n' >> "$managed_repair_path"
cp "$repair_original" "$repair_move_source"
output=$(wrq_run --json import --move "$repair_move_source")
status=$?
wrq_expect_status "reimport repairs a corrupt managed exact-hash asset" "$status" 0 "$output" "wrq_storage.md"
actual_repair_hash=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$managed_repair_path")
if [ ! -e "$repair_move_source" ] && [ -f "$managed_repair_path" ] && [ "$actual_repair_hash" = "$expected_repair_hash" ] && [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "--move deletes source only after corrupt asset repair" "source absent and one managed PDF with expected hash" "$output" "wrq_storage.md"
fi

wrq_use_library "import-missing-hash-repair"
missing_original="$WRQ_TEST_ROOT/missing-original.pdf"
missing_move_source="$WRQ_TEST_ROOT/missing-move-source.pdf"
wrq_make_pdf "$missing_original" "missing-repair-authoritative-bytes"
missing_output=$(wrq_run --json import "$missing_original")
missing_status=$?
wrq_expect_status "missing-asset fixture imports" "$missing_status" 0 "$missing_output" "wrq_storage.md"
managed_missing_path=$(printf '%s' "$missing_output" | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch(0).fetch("path")')
expected_missing_hash=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$missing_original")
rm "$managed_missing_path"
cp "$missing_original" "$missing_move_source"
output=$(wrq_run --json import --move "$missing_move_source")
status=$?
wrq_expect_status "reimport repairs a missing managed exact-hash asset" "$status" 0 "$output" "wrq_storage.md"
actual_missing_hash=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$managed_missing_path")
if [ ! -e "$missing_move_source" ] && [ -f "$managed_missing_path" ] && [ "$actual_missing_hash" = "$expected_missing_hash" ] && [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "--move deletes source only after missing asset repair" "source absent and one restored managed PDF with expected hash" "$output" "wrq_storage.md"
fi

wrq_use_library "import-arxiv-version-metadata"
version_one="$WRQ_TEST_ROOT/1706.03762v1-Trusted-Findings.pdf"
version_two="$WRQ_TEST_ROOT/1706.03762v2-Untrusted-Filename.pdf"
wrq_make_pdf "$version_one" "arxiv-version-one"
output=$(wrq_run --json import "$version_one")
status=$?
wrq_expect_status "first inferred arXiv version imports" "$status" 0 "$output" "wrq_storage.md"
output=$(wrq_run --json meta 1706.03762 --venue NeurIPS --year 2025 --status read --tag trusted)
status=$?
wrq_expect_status "trusted arXiv metadata is recorded" "$status" 0 "$output" "wrq_storage.md"
before_added_at=$(printf '%s' "$output" | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("metadata").fetch("added_at")')

wrq_make_pdf "$version_two" "arxiv-version-two"
output=$(wrq_run --json import "$version_two")
status=$?
wrq_expect_status "additional inferred arXiv version imports" "$status" 0 "$output" "wrq_storage.md"
output=$(wrq_run --json info 1706.03762)
status=$?
wrq_expect_status "multi-version arXiv info succeeds" "$status" 0 "$output" "wrq_storage.md"
wrq_expect_json "new version preserves trusted and user-owned metadata" "$output" '
  metadata = value["metadata"]
  metadata["title"] == "Trusted Findings" && metadata["venue"] == "NeurIPS" &&
    metadata["year"] == 2025 && metadata["status"] == "read" &&
    metadata["tags"] == ["trusted"] && value["assets"].length == 2
' "wrq_storage.md"
after_added_at=$(printf '%s' "$output" | ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("metadata").fetch("added_at")')
if [ "$before_added_at" = "$after_added_at" ]; then
  wrq_pass
else
  wrq_fail "additional version preserves original added_at" "$before_added_at" "$after_added_at" "wrq_storage.md"
fi

version_one_path=$(wrq_run --print-path open 1706.03762v1)
status=$?
wrq_expect_status "exact-version open succeeds" "$status" 0 "$version_one_path" "wrq_command_line.md"
if [ -f "$version_one_path" ] && grep -F -q -- "arxiv-version-one" "$version_one_path" && ! grep -F -q -- "arxiv-version-two" "$version_one_path"; then
  wrq_pass
else
  wrq_fail "exact-version open selects the requested asset" "v1 PDF bytes" "$version_one_path" "wrq_command_line.md"
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
