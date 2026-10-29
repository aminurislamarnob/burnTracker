#!/usr/bin/env bash
# Feedback loop for Antigravity quota: red when only CSRF-less localhost
# answers (BurnTracker's previous path), green when `agy -p=/usage` works (Orca).
set -euo pipefail

AGY_BIN="${AGY_BIN:-$(command -v agy || true)}"
PORTS="$(lsof -nP -iTCP -sTCP:LISTEN -a -c agy 2>/dev/null | awk '{print $9}' | sed -n 's/.*:\([0-9]*\)$/\1/p' | sort -u || true)"

ls_ok=0
cli_ok=0

for port in $PORTS; do
  code="$(curl -sk -o /tmp/bt-ag-ls.json -w '%{http_code}' \
    -X POST "https://127.0.0.1:${port}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary" \
    -H 'Content-Type: application/json' \
    -H 'Connect-Protocol-Version: 1' \
    -d '{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}' \
    || true)"
  if [[ "$code" == "200" ]] && grep -q '"groups"' /tmp/bt-ag-ls.json 2>/dev/null; then
    ls_ok=1
  fi
  echo "language-server port=${port} http=${code}"
done

if [[ -n "$AGY_BIN" ]]; then
  if AGY_CLI_DISABLE_AUTO_UPDATE=true "$AGY_BIN" \
      --output-format json --print-timeout 20s -p=/usage \
      > /tmp/bt-ag-cli.json 2>/tmp/bt-ag-cli.err; then
    if grep -q '"status":"SUCCESS"' /tmp/bt-ag-cli.json \
      && grep -q '"name":"usage"' /tmp/bt-ag-cli.json; then
      cli_ok=1
    fi
  fi
  echo "cli_usage ok=${cli_ok}"
else
  echo "cli_usage missing_binary"
fi

if [[ "$cli_ok" -eq 1 || "$ls_ok" -eq 1 ]]; then
  echo "RESULT: GREEN (usable quota source: ls=${ls_ok} cli=${cli_ok})"
  exit 0
fi

echo "RESULT: RED (no usable Antigravity quota source)"
exit 1
