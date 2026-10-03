#!/usr/bin/env bash
# End-to-end test against the fake claude CLI. Works on Linux, macOS and Git Bash.
set -euo pipefail
cd "$(dirname "$0")/.."

zig build
zig build fake

ext=""
topath() { printf '%s' "$1"; }
if [[ "${OS:-}" == "Windows_NT" ]]; then
  ext=".exe"
  topath() { cygpath -m "$1"; }
fi

EXE="zig-out/bin/claudegpt$ext"
FAKE=$(topath "$PWD/zig-out/bin/fake_claude$ext")
ROOT_DIR=$(mktemp -d)
ROOT=$(topath "$ROOT_DIR")
OUTSIDE=$(topath "$(mktemp -d)")
PORT=${PORT:-18765}
URL="http://127.0.0.1:$PORT/mcp"
export CLAUDEGPT_TOKEN=test-token-0123456789

"$EXE" --port "$PORT" --root "$ROOT" --claude-path "$FAKE" &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
for _ in $(seq 100); do
  curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && break
  sleep 0.1
done

rpc() {
  curl -sS -X POST "$URL" -H "Authorization: Bearer $CLAUDEGPT_TOKEN" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$1"
}
call() { rpc "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }
expect() {
  if ! grep -qF -- "$2" <<<"$1"; then
    echo "FAIL: expected '$2' in:" >&2
    echo "$1" >&2
    exit 1
  fi
}

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" -d '{}')
[[ $code == 401 ]] || { echo "FAIL: unauthenticated request returned $code" >&2; exit 1; }

out=$(rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"it","version":"0"}}}')
expect "$out" '"protocolVersion":"2025-06-18"'

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" -H "Authorization: Bearer $CLAUDEGPT_TOKEN" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')
[[ $code == 202 ]] || { echo "FAIL: notification returned $code" >&2; exit 1; }

out=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
expect "$out" '"name":"claude_start"'

out=$(call claude_start "{\"cwd\":\"$ROOT\",\"prompt\":\"hello\",\"wait_seconds\":10}")
expect "$out" 'echo: hello'
expect "$out" '"completed":true'
expect "$out" 'tool_use: Read'
expect "$out" '"session_id":"11111111-2222-4333-8444-555555555555"'
ID=$(sed -n 's/.*"instance":{"id":"\([0-9a-f]\{8\}\)".*/\1/p' <<<"$out")
[[ -n $ID ]] || { echo "FAIL: no instance id in $out" >&2; exit 1; }

out=$(call claude_send "{\"id\":\"$ID\",\"prompt\":\"again\",\"wait_seconds\":10}")
expect "$out" 'echo: again'
expect "$out" '"completed_turns":2'

out=$(call claude_output "{\"id\":\"$ID\",\"since\":0}")
expect "$out" 'prompt: hello'
expect "$out" 'stderr: fake_claude: turn'
if grep -qE 'rate_limit_event|thinking_tokens' <<<"$out"; then echo "FAIL: noise events leaked into transcript" >&2; exit 1; fi

out=$(call claude_list '{}')
expect "$out" "\"id\":\"$ID\""

out=$(call claude_interrupt "{\"id\":\"$ID\"}")
expect "$out" '"isError":false'

out=$(call claude_stop "{\"id\":\"$ID\"}")
expect "$out" '"state":"exited"'

out=$(call claude_send "{\"id\":\"$ID\",\"prompt\":\"late\"}")
expect "$out" '"isError":true'

out=$(call claude_start "{\"cwd\":\"$OUTSIDE\"}")
expect "$out" 'outside the allowed roots'

echo "integration: PASS"
