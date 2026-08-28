#!/usr/bin/env bash

[ "${WRQ_ACCEPTANCE_ACTIVE:-}" = "1" ] || return 0

wrq_section "sources"

wrq_use_library "source-arxiv"
: > "$WRQ_FIXTURE_REQUEST_LOG"
output=$(wrq_run 1706.03762)
status=$?
wrq_expect_status "arXiv shorthand first fetch succeeds" "$status" 0 "$output" "wrq_sources.md"
wrq_expect_contains "arXiv shorthand reports download" "$output" "Downloaded: arxiv:1706.03762" "wrq_sources.md"
wrq_expect_contains "arXiv shorthand opens fetched paper" "$output" "Opened: arxiv:1706.03762" "wrq_command_line.md"
if [ "$(wc -l < "$WRQ_FIXTURE_REQUEST_LOG" | tr -d ' ')" -eq 2 ] && [ "$(wc -l < "$WRQ_TEST_OPEN_LOG" | tr -d ' ')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "first fetch performs metadata/PDF requests and opens once" "two HTTP requests and one opener entry" "$(cat "$WRQ_FIXTURE_REQUEST_LOG")" "wrq_sources.md"
fi

request_count=$(wc -l < "$WRQ_FIXTURE_REQUEST_LOG" | tr -d ' ')
output=$(wrq_run "https://arxiv.org/abs/1706.03762")
status=$?
wrq_expect_status "existing arXiv URL opens" "$status" 0 "$output" "wrq_command_line.md"
wrq_expect_contains "existing arXiv URL reports open" "$output" "Opened: arxiv:1706.03762"
if [ "$(wc -l < "$WRQ_FIXTURE_REQUEST_LOG" | tr -d ' ')" -eq "$request_count" ] && [ "$(wc -l < "$WRQ_TEST_OPEN_LOG" | tr -d ' ')" -eq 2 ]; then
  wrq_pass
else
  wrq_fail "existing paper opens offline without provider request" "unchanged request count and second opener entry" "$(cat "$WRQ_FIXTURE_REQUEST_LOG")" "wrq_command_line.md"
fi

output=$(wrq_run --print-path "https://arxiv.org/pdf/1706.03762.pdf")
status=$?
wrq_expect_status "canonical arXiv PDF URL resolves locally" "$status" 0 "$output" "wrq_sources.md"
if [ -f "$output" ] && [ "$(wc -l < "$WRQ_FIXTURE_REQUEST_LOG" | tr -d ' ')" -eq "$request_count" ]; then
  wrq_pass
else
  wrq_fail "arXiv PDF URL shares canonical local identity" "existing path and no new request" "$output" "wrq_sources.md"
fi

output=$(wrq_run --print-path "https://huggingface.co/papers/1706.03762")
status=$?
wrq_expect_status "existing HF URL resolves locally" "$status" 0 "$output" "wrq_sources.md"
if [ -f "$output" ] && [ "$(wc -l < "$WRQ_FIXTURE_REQUEST_LOG" | tr -d ' ')" -eq "$request_count" ]; then
  wrq_pass
else
  wrq_fail "HF URL aliases canonical arXiv identity" "existing path and no new request" "$output" "wrq_sources.md"
fi

output=$(wrq_run --json update 1706.03762)
status=$?
wrq_expect_status "update of an existing arXiv paper succeeds" "$status" 0 "$output" "wrq_sources.md"
wrq_expect_json "same-version update refreshes without redownload" "$output" '
  value.is_a?(Array) && value.length == 1 && value[0]["key"] == "arxiv:1706.03762" &&
    value[0]["version"] == 7 && value[0]["downloaded"] == false
' "wrq_storage.md"
if [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 1 ]; then
  wrq_pass
else
  wrq_fail "same-version update creates no duplicate asset" "one managed PDF" "$output" "wrq_storage.md"
fi

wrq_use_library "source-hf"
: > "$WRQ_FIXTURE_REQUEST_LOG"
output=$(wrq_run --no-open "https://huggingface.co/papers/1706.03762")
status=$?
wrq_expect_status "HF first fetch succeeds" "$status" 0 "$output" "wrq_sources.md"
if [ "$(wc -l < "$WRQ_FIXTURE_REQUEST_LOG" | tr -d ' ')" -eq 3 ]; then
  wrq_pass
else
  wrq_fail "HF first fetch uses arXiv metadata/PDF plus HF enrichment" "three local fixture requests" "$(cat "$WRQ_FIXTURE_REQUEST_LOG")" "wrq_sources.md"
fi
output=$(wrq_run --json info 1706.03762)
status=$?
wrq_expect_status "HF-enriched info succeeds" "$status" 0 "$output" "wrq_sources.md"
wrq_expect_json "HF metadata is stored without replacing arXiv identity" "$output" '
  value["key"] == "arxiv:1706.03762" && value.dig("metadata", "title") == "Attention Is All You Need" &&
    value.dig("metadata", "hf_summary") == "The Transformer uses attention without recurrence." &&
    value.dig("metadata", "provider_data", "hugging_face", "upvotes") == 4242 &&
    value.dig("metadata", "related_models", 0, "id") == "example/transformer" &&
    value.dig("metadata", "related_datasets", 0, "id") == "example/corpus" &&
    value.dig("metadata", "related_spaces", 0, "id") == "example/demo"
' "wrq_sources.md"

wrq_use_library "source-legacy"
: > "$WRQ_FIXTURE_REQUEST_LOG"
output=$(wrq_run --no-open "https://arxiv.org/abs/hep-th/9901001")
status=$?
wrq_expect_status "legacy arXiv URL fetch succeeds" "$status" 0 "$output" "wrq_sources.md"
output=$(wrq_run --json info "arXiv:hep-th/9901001v2")
status=$?
wrq_expect_status "legacy version alias resolves" "$status" 0 "$output" "wrq_sources.md"
wrq_expect_json "legacy paper retains base identity and resolved version" "$output" '
  value["key"] == "arxiv:hep-th/9901001" && value["assets"].length == 1 &&
    value["assets"][0]["version"] == 2 && value.dig("metadata", "title") == "A Legacy Identifier Paper"
' "wrq_sources.md"

wrq_use_library "source-incomplete-query"
: > "$WRQ_FIXTURE_REQUEST_LOG"
output=$(wrq_run --json 1706)
status=$?
wrq_expect_status "incomplete identifier is local search" "$status" 0 "$output" "wrq_command_line.md"
wrq_expect_json "incomplete identifier returns empty local results" "$output" 'value == []' "wrq_command_line.md"
if [ ! -s "$WRQ_FIXTURE_REQUEST_LOG" ]; then
  wrq_pass
else
  wrq_fail "arbitrary text never triggers network" "empty fixture request log" "$(cat "$WRQ_FIXTURE_REQUEST_LOG")" "wrq_command_line.md"
fi

wrq_use_library "source-not-found"
: > "$WRQ_FIXTURE_REQUEST_LOG"
output=$(wrq_run --no-open 2401.00001)
status=$?
wrq_expect_status "provider not-found is operational failure" "$status" 1 "$output" "wrq_sources.md"
wrq_expect_contains "provider not-found diagnostic" "$output" "not found" "wrq_sources.md"
if [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 0 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/records" '*.json')" -eq 0 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/tmp" '*')" -eq 0 ]; then
  wrq_pass
else
  wrq_fail "metadata failure creates no partial paper" "no PDF, record, or temporary file" "$output" "wrq_storage.md"
fi

wrq_use_library "source-invalid-pdf"
: > "$WRQ_FIXTURE_REQUEST_LOG"
saved_pdf_url="$WRQ_ARXIV_PDF_URL"
export WRQ_ARXIV_PDF_URL="$WRQ_FIXTURE_BASE_URL/not-pdf"
output=$(wrq_run add 1706.03762 --no-open)
status=$?
export WRQ_ARXIV_PDF_URL="$saved_pdf_url"
wrq_expect_status "invalid downloaded PDF is operational failure" "$status" 1 "$output" "wrq_storage.md"
wrq_expect_contains "invalid downloaded PDF diagnostic" "$output" "not a PDF" "wrq_storage.md"
if [ "$(wrq_file_count "$WRQ_PATH/library" '*.pdf')" -eq 0 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/records" '*.json')" -eq 0 ] && [ "$(wrq_file_count "$WRQ_PATH/.wrq/tmp" '*')" -eq 0 ]; then
  wrq_pass
else
  wrq_fail "failed download is transactional" "no PDF, record, or temporary file" "$output" "wrq_storage.md"
fi
