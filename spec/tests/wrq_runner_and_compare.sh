#!/usr/bin/env bash
# Run the full wrq acceptance suite against two executables, then compare a
# normalized behavioral transcript. Intended for MRI/Spinel parity checks.
# Usage: spec/tests/wrq_runner_and_compare.sh ./wrq.rb ./dist/wrq

set +e

COMPARE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wrq_runner.sh
# shellcheck disable=SC1091
source "$COMPARE_SCRIPT_DIR/wrq_runner.sh"

if [ "$#" -ne 2 ]; then
  printf 'Usage: %s /path/to/wrq-a /path/to/wrq-b\n' "$0" >&2
  exit 2
fi

COMPARE_BIN_A=$(wrq_absolute_executable "$1") || exit 1
COMPARE_BIN_B=$(wrq_absolute_executable "$2") || exit 1
for candidate in "$COMPARE_BIN_A" "$COMPARE_BIN_B"; do
  if [ ! -x "$candidate" ]; then
    printf 'Error: wrq executable does not exist or is not executable: %s\n' "$candidate" >&2
    exit 1
  fi
done

COMPARE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wrq-compare.XXXXXX") || exit 1
COMPARE_ROOT=$(cd "$COMPARE_ROOT" && pwd -P) || exit 1
COMPARE_SERVER_PID=""
# shellcheck disable=SC2329
compare_cleanup() {
  if [ -n "$COMPARE_SERVER_PID" ]; then
    kill "$COMPARE_SERVER_PID" 2>/dev/null
    wait "$COMPARE_SERVER_PID" 2>/dev/null
  fi
  if [ -d "$COMPARE_ROOT" ]; then
    rm -rf "$COMPARE_ROOT"
  fi
}
trap compare_cleanup EXIT INT TERM

printf 'Acceptance A: %s\n' "$COMPARE_BIN_A"
"$COMPARE_SCRIPT_DIR/wrq_runner.sh" "$COMPARE_BIN_A" >"$COMPARE_ROOT/acceptance-a.log" 2>&1
acceptance_a=$?
if [ "$acceptance_a" -eq 0 ]; then
  printf '%bA passed%b\n' "$WRQ_GREEN" "$WRQ_NC"
else
  printf '%bA failed%b\n' "$WRQ_RED" "$WRQ_NC"
  sed -n '1,240p' "$COMPARE_ROOT/acceptance-a.log"
fi

printf 'Acceptance B: %s\n' "$COMPARE_BIN_B"
"$COMPARE_SCRIPT_DIR/wrq_runner.sh" "$COMPARE_BIN_B" >"$COMPARE_ROOT/acceptance-b.log" 2>&1
acceptance_b=$?
if [ "$acceptance_b" -eq 0 ]; then
  printf '%bB passed%b\n' "$WRQ_GREEN" "$WRQ_NC"
else
  printf '%bB failed%b\n' "$WRQ_RED" "$WRQ_NC"
  sed -n '1,240p' "$COMPARE_ROOT/acceptance-b.log"
fi

if [ "$acceptance_a" -ne 0 ] || [ "$acceptance_b" -ne 0 ]; then
  printf '%bCannot compare implementations until both pass acceptance.%b\n' "$WRQ_RED" "$WRQ_NC"
  exit 1
fi

WRQ_TEST_ROOT="$COMPARE_ROOT/runtime"
WRQ_FIXTURE_DIR="$WRQ_REPO_DIR/test/fixtures/wrq"
export WRQ_FIXTURE_DIR
mkdir -p "$WRQ_TEST_ROOT"
if ! wrq_start_fixture_server "$WRQ_TEST_ROOT"; then
  printf 'Error: could not start comparison fixture server\n' >&2
  exit 1
fi
COMPARE_SERVER_PID="$WRQ_FIXTURE_SERVER_PID"
WRQ_FIXTURE_SERVER_PID=""

compare_sources="$COMPARE_ROOT/sources"
compare_primary="$compare_sources/Compare-Paper.pdf"
compare_duplicate="$compare_sources/Compare-Paper-Copy.pdf"
wrq_make_pdf "$compare_primary" "compare"
cp "$compare_primary" "$compare_duplicate"

compare_record() {
  local executable="$1" root="$2" label="$3"
  shift 3
  local output status
  output=$(env \
    HOME="$COMPARE_ROOT/home" \
    WRQ_PATH="$root" \
    WRQ_TEST_OPEN_LOG="$root/opener.log" \
    WRQ_ARXIV_API_URL="$WRQ_FIXTURE_BASE_URL/api/query" \
    WRQ_ARXIV_PDF_URL="$WRQ_FIXTURE_BASE_URL/pdf" \
    WRQ_HF_API_URL="$WRQ_FIXTURE_BASE_URL/api/papers" \
    WRQ_ARXIV_THROTTLE_PATH="$root/arxiv-api.throttle" \
    NO_COLOR=1 WRQ_WIDTH=80 WRQ_HEIGHT=24 \
    "$executable" "$@" 2>&1)
  status=$?
  printf '=== %s\n%s\n[status=%s]\n' "$label" "$output" "$status"
}

compare_scenario() {
  local executable="$1" root="$2"
  mkdir -p "$COMPARE_ROOT/home"
  compare_record "$executable" "$root" help --help
  compare_record "$executable" "$root" version --version
  compare_record "$executable" "$root" usage-error import
  compare_record "$executable" "$root" import --json import "$compare_primary"
  compare_record "$executable" "$root" duplicate-import --json import "$compare_duplicate"
  compare_record "$executable" "$root" metadata --json meta "compare paper" \
    --venue NeurIPS --year 2025 --status read --tag comparison
  compare_record "$executable" "$root" info --json info "compare paper"
  compare_record "$executable" "$root" search --json search comparison
  compare_record "$executable" "$root" print-path --print-path "compare paper"
  compare_record "$executable" "$root" dedupe --json dedupe "$compare_duplicate"
  compare_record "$executable" "$root" doctor --json doctor
  compare_record "$executable" "$root" provider --json --no-open add \
    "https://huggingface.co/papers/1706.03762"
  compare_record "$executable" "$root" provider-existing --print-path \
    "https://arxiv.org/abs/1706.03762"
  compare_record "$executable" "$root" remove --json remove --yes "compare paper"
}

root_a="$COMPARE_ROOT/library-a"
root_b="$COMPARE_ROOT/library-b"
compare_scenario "$COMPARE_BIN_A" "$root_a" > "$COMPARE_ROOT/raw-a.txt"
compare_scenario "$COMPARE_BIN_B" "$root_b" > "$COMPARE_ROOT/raw-b.txt"

compare_normalize() {
  local source="$1" destination="$2" library_root="$3"
  ruby -e '
    source, destination, library_root, test_root = ARGV
    text = File.binread(source)
    text.gsub!(/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    text.gsub!(library_root, "<WRQ_PATH>")
    text.gsub!(test_root, "<TEST_ROOT>")
    text.gsub!(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})/, "<TIMESTAMP>")
    text.gsub!(%r{(\.wrq/trash/)\d{14}}, "\\1<TIMESTAMP>")
    text.gsub!(/("score"\s*:\s*)[-+0-9.eE]+/, "\\1<SCORE>")
    # json 2.7 and 2.10 format empty containers differently in pretty mode.
    # Normalize that presentation detail before comparing CLI behavior.
    text.gsub!(/\[\s*\]/, "[]")
    text.gsub!(/\{\s*\}/, "{}")
    File.binwrite(destination, text)
  ' "$source" "$destination" "$library_root" "$COMPARE_ROOT"
}

compare_normalize "$COMPARE_ROOT/raw-a.txt" "$COMPARE_ROOT/normalized-a.txt" "$root_a"
compare_normalize "$COMPARE_ROOT/raw-b.txt" "$COMPARE_ROOT/normalized-b.txt" "$root_b"

if cmp -s "$COMPARE_ROOT/normalized-a.txt" "$COMPARE_ROOT/normalized-b.txt"; then
  printf '%bMRI/native behavioral transcripts match.%b\n' "$WRQ_GREEN" "$WRQ_NC"
  exit 0
fi

printf '%bMRI/native behavioral transcripts differ:%b\n' "$WRQ_RED" "$WRQ_NC"
diff -u "$COMPARE_ROOT/normalized-a.txt" "$COMPARE_ROOT/normalized-b.txt" | sed -n '1,160p'
exit 1
