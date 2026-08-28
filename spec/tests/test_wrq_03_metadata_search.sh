#!/usr/bin/env bash

[ "${WRQ_ACCEPTANCE_ACTIVE:-}" = "1" ] || return 0

wrq_section "metadata-search"

wrq_use_library "metadata-search"
source_pdf="$WRQ_TEST_ROOT/Graph-Neural-Networks.pdf"
wrq_make_pdf "$source_pdf" "metadata"
import_output=$(wrq_run --json import "$source_pdf")
import_status=$?
wrq_expect_status "metadata fixture imports" "$import_status" 0 "$import_output" "wrq_storage.md"

output=$(wrq_run meta "graph neural networks" \
  --venue NeurIPS --year 2025 --track "Datasets and Benchmarks" \
  --status read --decision accepted --doi "https://doi.org/10.1234/wrq.2025" \
  --tag graphs --tag foundational --tag graphs --json)
status=$?
wrq_expect_status "metadata update succeeds" "$status" 0 "$output"
wrq_expect_json "metadata JSON includes user fields" "$output" '
  metadata = value["metadata"]
  metadata["venue"] == "NeurIPS" && metadata["year"] == 2025 &&
    metadata["track"] == "Datasets and Benchmarks" && metadata["status"] == "read" &&
    metadata["decision"] == "accepted" && metadata["publication_doi"] == "10.1234/wrq.2025" &&
    metadata["tags"] == ["graphs", "foundational"] && metadata.dig("provenance", "venue") == "manual"
' "wrq_storage.md"

output=$(wrq_run --json meta "graph neural" --remove-tag graphs --tag survey)
status=$?
wrq_expect_status "tag removal and addition succeeds" "$status" 0 "$output"
wrq_expect_json "tag edit is reflected in JSON" "$output" 'value.dig("metadata", "tags") == ["foundational", "survey"]' "wrq_storage.md"

output=$(wrq_run info "graph neural")
status=$?
wrq_expect_status "plain info succeeds" "$status" 0 "$output"
wrq_expect_contains "plain info displays title" "$output" "Graph Neural Networks"
wrq_expect_contains "plain info displays venue" "$output" "Venue: NeurIPS"
wrq_expect_contains "plain info displays tags" "$output" "Tags: foundational, survey"
wrq_expect_contains "plain info includes asset hashes" "$output" "Sha256:"
wrq_expect_contains "plain info includes all conference fields" "$output" "Decision: accepted"

output=$(wrq_run --json info "graph neural")
status=$?
wrq_expect_status "JSON info succeeds" "$status" 0 "$output"
wrq_expect_json "JSON info is complete and has an asset path" "$output" '
  value["schema_version"].is_a?(Integer) && value["key"].start_with?("sha256:") &&
    value["metadata"]["title"] == "Graph Neural Networks" && File.file?(value["current_path"])
' "wrq_storage.md"

output=$(wrq_run --json search "graph neural")
status=$?
wrq_expect_status "fuzzy JSON search succeeds" "$status" 0 "$output"
wrq_expect_json "fuzzy JSON search finds title" "$output" '
  value.is_a?(Array) && value.length == 1 && value[0]["matched_field"] == "title" &&
    value[0].dig("paper", "metadata", "title") == "Graph Neural Networks" &&
    value[0]["title_highlight_positions"].is_a?(Array)
' "wrq_command_line.md"

output=$(wrq_run search survey --json)
status=$?
wrq_expect_status "tag JSON search succeeds" "$status" 0 "$output"
wrq_expect_json "tag search reports its matched field" "$output" 'value.length == 1 && value[0]["matched_field"] == "tags"' "wrq_command_line.md"

output=$(wrq_run search "neurips survey" --json)
status=$?
wrq_expect_status "cross-field JSON search succeeds" "$status" 0 "$output"
wrq_expect_json "query terms can match venue and tags" "$output" 'value.length == 1 && value[0]["matched_field"] == "multiple"' "wrq_command_line.md"

path_output=$(wrq_run "gph nrl" --print-path)
status=$?
wrq_expect_status "shorthand fuzzy --print-path succeeds" "$status" 0 "$path_output"
if [ -f "$path_output" ] && printf '%s' "$path_output" | grep -F -q -- "$WRQ_PATH/library/"; then
  wrq_pass
else
  wrq_fail "--print-path emits the selected absolute PDF" "an existing path under the managed library" "$path_output" "wrq_command_line.md"
fi

output=$(wrq_run open "graph neural" --no-open)
status=$?
wrq_expect_status "--no-open resolves without a viewer" "$status" 0 "$output"
wrq_expect_contains "--no-open reports stored path" "$output" "Stored: $WRQ_PATH/library/"
if [ ! -e "$WRQ_TEST_OPEN_LOG" ]; then
  wrq_pass
else
  wrq_fail "--no-open never launches viewer" "no opener log" "$(cat "$WRQ_TEST_OPEN_LOG")" "wrq_command_line.md"
fi

output=$(wrq_run --json search "not-a-subsequence-anywhere")
status=$?
wrq_expect_status "empty JSON search succeeds" "$status" 0 "$output"
wrq_expect_json "empty JSON search is an empty array" "$output" 'value == []'

output=$(wrq_run meta "graph neural" --year 25)
status=$?
wrq_expect_status "invalid metadata year is usage error" "$status" 2 "$output"
output=$(wrq_run meta "graph neural" --doi not-a-doi)
status=$?
wrq_expect_status "invalid DOI is usage error" "$status" 2 "$output"
output=$(wrq_run meta "graph neural")
status=$?
wrq_expect_status "metadata update without changes is usage error" "$status" 2 "$output"
