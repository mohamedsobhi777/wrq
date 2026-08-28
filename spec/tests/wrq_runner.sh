#!/usr/bin/env bash
# Implementation-neutral acceptance runner for wrq.
# Usage: spec/tests/wrq_runner.sh /path/to/wrq

set +e

WRQ_RED='\033[0;31m'
WRQ_GREEN='\033[0;32m'
WRQ_YELLOW='\033[1;33m'
WRQ_NC='\033[0m'

WRQ_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRQ_SPEC_DIR="$(dirname "$WRQ_SCRIPT_DIR")"
WRQ_REPO_DIR="$(dirname "$WRQ_SPEC_DIR")"

wrq_absolute_executable() {
  local candidate="$1"
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *)
      local directory basename
      directory=$(dirname "$candidate")
      basename=$(basename "$candidate")
      directory=$(cd "$directory" 2>/dev/null && pwd) || return 1
      printf '%s/%s\n' "$directory" "$basename"
      ;;
  esac
}

wrq_run() {
  "$WRQ_BIN_PATH" "$@" 2>&1
}

wrq_use_library() {
  local name="$1"
  export WRQ_PATH="$WRQ_TEST_ROOT/libraries/$name"
  export WRQ_TEST_OPEN_LOG="$WRQ_TEST_ROOT/open-$name.log"
}

wrq_make_pdf() {
  local destination="$1"
  local marker="${2:-fixture}"
  mkdir -p "$(dirname "$destination")"
  cp "$WRQ_FIXTURE_DIR/minimal.pdf" "$destination" || return 1
  printf '\n%% wrq acceptance fixture: %s\n' "$marker" >> "$destination"
}

wrq_file_count() {
  local directory="$1"
  local pattern="${2:-*}"
  if [ ! -d "$directory" ]; then
    printf '0\n'
    return
  fi
  find "$directory" -type f -name "$pattern" -print | wc -l | tr -d ' '
}

wrq_json_check() {
  local payload="$1"
  local expression="$2"
  printf '%s' "$payload" | ruby -rjson -e '
    value = JSON.parse(STDIN.read)
    expression = ARGV.fetch(0)
    exit(eval(expression, binding, "wrq-acceptance-expression", 1) ? 0 : 1)
  ' "$expression" >/dev/null 2>&1
}

wrq_pass() {
  printf '%b.%b' "$WRQ_GREEN" "$WRQ_NC"
  WRQ_TESTS_PASSED=$((WRQ_TESTS_PASSED + 1))
  WRQ_TESTS_RUN=$((WRQ_TESTS_RUN + 1))
}

wrq_fail() {
  local name="$1"
  local expected="${2:-}"
  local output="${3:-}"
  local spec="${4:-}"
  printf '\n%bFAIL%b: %s\n' "$WRQ_RED" "$WRQ_NC" "$name"
  [ -n "$expected" ] && printf '  Expected: %s\n' "$expected"
  [ -n "$output" ] && printf '  Output:\n%s\n' "$output"
  [ -n "$spec" ] && printf '  %bSpec: %s/%s%b\n' "$WRQ_YELLOW" "$WRQ_SPEC_DIR" "$spec" "$WRQ_NC"
  WRQ_TESTS_FAILED=$((WRQ_TESTS_FAILED + 1))
  WRQ_TESTS_RUN=$((WRQ_TESTS_RUN + 1))
}

wrq_section() {
  printf '\n%b%s%b ' "$WRQ_YELLOW" "$1" "$WRQ_NC"
}

wrq_expect_status() {
  local name="$1" actual="$2" expected="$3" output="${4:-}" spec="${5:-wrq_command_line.md}"
  if [ "$actual" -eq "$expected" ] 2>/dev/null; then
    wrq_pass
  else
    wrq_fail "$name" "exit $expected (got $actual)" "$output" "$spec"
  fi
}

wrq_expect_contains() {
  local name="$1" output="$2" needle="$3" spec="${4:-wrq_command_line.md}"
  if printf '%s\n' "$output" | grep -F -q -- "$needle"; then
    wrq_pass
  else
    wrq_fail "$name" "output containing: $needle" "$output" "$spec"
  fi
}

wrq_expect_matches() {
  local name="$1" output="$2" pattern="$3" spec="${4:-wrq_command_line.md}"
  if printf '%s\n' "$output" | grep -E -q -- "$pattern"; then
    wrq_pass
  else
    wrq_fail "$name" "output matching: $pattern" "$output" "$spec"
  fi
}

wrq_expect_json() {
  local name="$1" output="$2" expression="$3" spec="${4:-wrq_command_line.md}"
  if wrq_json_check "$output" "$expression"; then
    wrq_pass
  else
    wrq_fail "$name" "JSON condition: $expression" "$output" "$spec"
  fi
}

wrq_expect_true() {
  local name="$1" spec="$2"
  shift 2
  if "$@"; then
    wrq_pass
  else
    wrq_fail "$name" "successful check: $*" "" "$spec"
  fi
}

wrq_start_fixture_server() {
  local runtime_root="$1"
  WRQ_FIXTURE_PORT_FILE="$runtime_root/fixture-server.port"
  WRQ_FIXTURE_REQUEST_LOG="$runtime_root/fixture-server.requests"
  : > "$WRQ_FIXTURE_REQUEST_LOG"
  rm -f "$WRQ_FIXTURE_PORT_FILE"

  ruby -rsocket -ruri -e '
    port_file, fixture_dir, request_log = ARGV
    server = TCPServer.new("127.0.0.1", 0)
    File.open(port_file, "w") { |file| file.write(server.addr[1].to_s) }
    stop = proc do
      begin
        server.close
      rescue IOError, SystemCallError
      end
      exit
    end
    Signal.trap("TERM", &stop)
    Signal.trap("INT", &stop)

    loop do
      socket = begin
        server.accept
      rescue IOError, SystemCallError
        break
      end
      begin
        request_line = socket.gets.to_s
        while (line = socket.gets)
          break if line == "\r\n" || line == "\n"
        end
        method, target = request_line.split(" ", 3)
        File.open(request_log, "a") { |file| file.puts("#{method} #{target}") }

        status = "200 OK"
        content_type = "application/octet-stream"
        body = ""
        slow = false
        decoded = URI.decode_www_form_component(target.to_s)
        case target.to_s
        when %r{\A/api/query}
          content_type = "application/atom+xml"
          fixture = if decoded.include?("hep-th/9901001")
            "arxiv_legacy.atom"
          elsif decoded.include?("1706.03762")
            "arxiv_attention.atom"
          else
            "arxiv_not_found.atom"
          end
          body = File.binread(File.join(fixture_dir, fixture))
        when %r{\A/api/papers/1706\.03762(?:\?|\z)}
          content_type = "application/json"
          body = File.binread(File.join(fixture_dir, "hugging_face_attention.json"))
        when %r{\A/not-pdf/}
          content_type = "text/plain"
          body = File.binread(File.join(fixture_dir, "not_a_pdf.txt"))
        when %r{\A/slow-pdf/}
          content_type = "application/pdf"
          body = File.binread(File.join(fixture_dir, "minimal.pdf")) + ("x" * 262_144)
          slow = true
        when %r{\A/pdf/}
          content_type = "application/pdf"
          body = File.binread(File.join(fixture_dir, "minimal.pdf"))
        else
          status = "404 Not Found"
          content_type = "text/plain"
          body = "not found\n"
        end

        socket.write("HTTP/1.1 #{status}\r\n")
        socket.write("Content-Type: #{content_type}\r\n")
        socket.write("Content-Length: #{body.bytesize}\r\n")
        socket.write("Connection: close\r\n\r\n")
        if slow
          socket.write(body.byteslice(0, 64))
          socket.flush
          sleep 10
          socket.write(body.byteslice(64, body.bytesize - 64))
        else
          socket.write(body)
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError, SystemCallError
      ensure
        begin
          socket.close
        rescue IOError, SystemCallError
        end
      end
    end
  ' "$WRQ_FIXTURE_PORT_FILE" "$WRQ_FIXTURE_DIR" "$WRQ_FIXTURE_REQUEST_LOG" \
    >"$runtime_root/fixture-server.out" 2>"$runtime_root/fixture-server.err" &
  WRQ_FIXTURE_SERVER_PID=$!

  local attempts=0
  while [ ! -s "$WRQ_FIXTURE_PORT_FILE" ] && [ "$attempts" -lt 100 ]; do
    if ! kill -0 "$WRQ_FIXTURE_SERVER_PID" 2>/dev/null; then
      return 1
    fi
    sleep 0.05
    attempts=$((attempts + 1))
  done
  [ -s "$WRQ_FIXTURE_PORT_FILE" ] || return 1

  WRQ_FIXTURE_PORT=$(cat "$WRQ_FIXTURE_PORT_FILE")
  WRQ_FIXTURE_BASE_URL="http://127.0.0.1:$WRQ_FIXTURE_PORT"
  export WRQ_ARXIV_API_URL="$WRQ_FIXTURE_BASE_URL/api/query"
  export WRQ_ARXIV_PDF_URL="$WRQ_FIXTURE_BASE_URL/pdf"
  export WRQ_HF_API_URL="$WRQ_FIXTURE_BASE_URL/api/papers"
  export WRQ_ARXIV_THROTTLE_PATH="$runtime_root/arxiv-api.throttle"
  export WRQ_FIXTURE_REQUEST_LOG WRQ_FIXTURE_BASE_URL
  return 0
}

wrq_stop_fixture_server() {
  if [ -n "${WRQ_FIXTURE_SERVER_PID:-}" ]; then
    kill "$WRQ_FIXTURE_SERVER_PID" 2>/dev/null
    wait "$WRQ_FIXTURE_SERVER_PID" 2>/dev/null
    WRQ_FIXTURE_SERVER_PID=""
  fi
}

wrq_acceptance_cleanup() {
  wrq_stop_fixture_server
  if [ -n "${WRQ_TEST_ROOT:-}" ] && [ -d "$WRQ_TEST_ROOT" ]; then
    rm -rf "$WRQ_TEST_ROOT"
  fi
}

wrq_acceptance_main() {
  if [ "$#" -ne 1 ]; then
    printf 'Usage: %s /path/to/wrq\n' "$0" >&2
    return 2
  fi
  if ! command -v ruby >/dev/null 2>&1; then
    printf 'Error: ruby is required to validate JSON and run local HTTP fixtures\n' >&2
    return 1
  fi

  WRQ_BIN_PATH=$(wrq_absolute_executable "$1") || {
    printf 'Error: cannot resolve wrq executable: %s\n' "$1" >&2
    return 1
  }
  if [ ! -x "$WRQ_BIN_PATH" ]; then
    printf 'Error: wrq executable does not exist or is not executable: %s\n' "$WRQ_BIN_PATH" >&2
    return 1
  fi

  WRQ_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wrq-acceptance.XXXXXX") || return 1
  # BSD mktemp preserves a trailing slash from TMPDIR (yielding //), while
  # File.expand_path in wrq canonicalizes it. Use one physical absolute form
  # for path assertions and cross-platform transcript comparison.
  WRQ_TEST_ROOT=$(cd "$WRQ_TEST_ROOT" && pwd -P) || return 1
  WRQ_FIXTURE_DIR="$WRQ_REPO_DIR/test/fixtures/wrq"
  if [ ! -f "$WRQ_FIXTURE_DIR/minimal.pdf" ]; then
    printf 'Error: wrq fixtures not found under %s\n' "$WRQ_FIXTURE_DIR" >&2
    wrq_acceptance_cleanup
    return 1
  fi

  export WRQ_BIN_PATH WRQ_TEST_ROOT WRQ_FIXTURE_DIR WRQ_SPEC_DIR WRQ_REPO_DIR
  export WRQ_ACCEPTANCE_ACTIVE=1
  export WRQ_WIDTH=80 WRQ_HEIGHT=24 NO_COLOR=1
  export HOME="$WRQ_TEST_ROOT/home"
  mkdir -p "$HOME"
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

  WRQ_TESTS_RUN=0
  WRQ_TESTS_PASSED=0
  WRQ_TESTS_FAILED=0
  trap wrq_acceptance_cleanup EXIT INT TERM

  if ! wrq_start_fixture_server "$WRQ_TEST_ROOT"; then
    printf 'Error: could not start the local fixture HTTP server\n' >&2
    [ -f "$WRQ_TEST_ROOT/fixture-server.err" ] && sed -n '1,40p' "$WRQ_TEST_ROOT/fixture-server.err" >&2
    return 1
  fi

  printf 'Testing wrq: %s\n' "$WRQ_BIN_PATH"
  printf 'Specifications: %s\n' "$WRQ_SPEC_DIR"
  printf 'Isolated test root: %s\n' "$WRQ_TEST_ROOT"

  local test_file
  for test_file in "$WRQ_SCRIPT_DIR"/test_wrq_*.sh; do
    [ -f "$test_file" ] || continue
    set +e
    # shellcheck source=/dev/null
    source "$test_file"
  done

  printf '\n\n===================================\n'
  printf 'Results: %s/%s passed\n' "$WRQ_TESTS_PASSED" "$WRQ_TESTS_RUN"
  if [ "$WRQ_TESTS_FAILED" -gt 0 ]; then
    printf '%b%s test(s) failed%b\n' "$WRQ_RED" "$WRQ_TESTS_FAILED" "$WRQ_NC"
    return 1
  fi
  printf '%bAll wrq acceptance tests passed%b\n' "$WRQ_GREEN" "$WRQ_NC"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  wrq_acceptance_main "$@"
  exit $?
fi
