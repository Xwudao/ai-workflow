#!/usr/bin/env bash
# Open a private SSH tunnel to the WAF dashboard on txsp.
set -Eeuo pipefail

HOST="${TXSP_HOST:-txsp}"
LOCAL_PORT="${WAF_DASHBOARD_PORT:-13002}"
REMOTE_PORT="${WAF_DASHBOARD_REMOTE_PORT:-13002}"
URL="http://127.0.0.1:${LOCAL_PORT}/waf"

ssh_pid=""
cleanup() {
  if [[ -n "${ssh_pid}" ]] && kill -0 "${ssh_pid}" 2>/dev/null; then
    echo
    echo "Stopping WAF dashboard tunnel..."
    kill "${ssh_pid}" 2>/dev/null || true
    wait "${ssh_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

ssh -N \
  -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
  "${HOST}" &
ssh_pid=$!

sleep 0.2
if ! kill -0 "${ssh_pid}" 2>/dev/null; then
  wait "${ssh_pid}"
fi

echo "WAF Dashboard: ${URL}"
echo "Press Ctrl-C or close this terminal to stop the SSH tunnel."
wait "${ssh_pid}"
