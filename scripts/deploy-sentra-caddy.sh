#!/usr/bin/env bash
# Deploy the Sentra-based Caddy (with the embedded admin SPA) to a remote host.
#
# Flow:
#   1. build SPA            (cd web && pnpm build, embed into internal/webassets/dist)
#   2. run go tests         (skippable)
#   3. xcaddy build         (linux/amd64, sentra + cloudflare/dynamicdns/transform-encoder)
#   4. upload               (binary, optional Caddyfile, remote helper)
#   5. validate             (new binary + temp admin port/db, no downtime)
#   6. backup + swap        (/root/sentra-deploy-backups/<ts>, then restart)
#   7. verify               (service active, SPA assets served, WAF probe);
#      failure restarts the previous binary automatically.
#
# Usage:
#   scripts/deploy-sentra-caddy.sh [options]
#   scripts/deploy-sentra-caddy.sh --rollback        # restore last backup
#
# Options:
#   -H, --host <alias>        SSH host alias            (default: txsp2)
#   -d, --dir <path>          Sentra checkout           (default: ~/Codes/sentra)
#   -c, --caddyfile <path>    also deploy this Caddyfile (default: binary only)
#   -b, --backup-root <path>  remote backup root        (default: /root/sentra-deploy-backups)
#   -n, --keep <count>        keep N remote backups     (default: 5)
#       --binary <path>       deploy a prebuilt binary  (skips web/tests/build)
#       --skip-web            do not rebuild the SPA
#       --skip-tests          do not run go tests
#       --rollback            restore the last deploy backup on the host
#   -y, --yes                 skip the confirmation prompt
#   -h, --help                show this help
#
# Env overrides: HOST, SENTRA_DIR, CADDY_VERSION, TARGET_OS, TARGET_ARCH,
#   REMOTE_BIN, REMOTE_SERVICE, REMOTE_CADDYFILE, SERVICE_USER, BACKUP_ROOT,
#   KEEP_BACKUPS, PROBE_HOSTS, ADMIN_URL, VALIDATE_ADMIN_LISTEN, VALIDATE_DB.
#
# PROBE_HOSTS defaults to the txsp2 site list; set PROBE_HOSTS="" to skip the
# WAF smoke test. See docs/txsp2-sentra-waf-migration.md for architecture.
set -Eeuo pipefail

SENTRA_DIR="${SENTRA_DIR:-$HOME/Codes/go/sentra}"
HOST="${HOST:-txsp2}"
CADDY_VERSION="${CADDY_VERSION:-v2.11.4}"
TARGET_OS="${TARGET_OS:-linux}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
REMOTE_BIN="${REMOTE_BIN:-/usr/local/sbin/caddy}"
REMOTE_SERVICE="${REMOTE_SERVICE:-caddy}"
REMOTE_CADDYFILE="${REMOTE_CADDYFILE:-/etc/caddy/Caddyfile}"
SERVICE_USER="${SERVICE_USER:-caddy}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/sentra-deploy-backups}"
STATE_FILE="${STATE_FILE:-/root/.sentra-last-deploy-backup}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
ADMIN_URL="${ADMIN_URL:-http://127.0.0.1:2020}"
VALIDATE_ADMIN_LISTEN="${VALIDATE_ADMIN_LISTEN:-127.0.0.1:2021}"
VALIDATE_DB="${VALIDATE_DB:-/tmp/sentra-validate.db}"

CADDYFILE=""
PREBUILT_BINARY=""
ROLLBACK=0
SKIP_WEB=0
SKIP_TESTS=0
ASSUME_YES=0

# Caddy modules to keep. Order does not matter; the local sentra checkout wins
# over the published module via a path replacement.
MODULES=(
  "github.com/Xwudao/sentra=${SENTRA_DIR}"
  "github.com/caddy-dns/cloudflare@v0.2.4"
  "github.com/caddyserver/transform-encoder@v0.0.0-20260423033309-ba4124974830"
  "github.com/mholt/caddy-dynamicdns@v0.0.0-20260805195708-67d107a42c02"
)

if [[ -z "${PROBE_HOSTS+x}" ]]; then
  case "$HOST" in
    txsp2) PROBE_HOSTS="hunhepan.com fuxipan.com lzpanx.com" ;;
    *)     PROBE_HOSTS="" ;;
  esac
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host)        HOST="$2"; shift 2 ;;
    -d|--dir)         SENTRA_DIR="$2"; MODULES[0]="github.com/Xwudao/sentra=${SENTRA_DIR}"; shift 2 ;;
    -c|--caddyfile)   CADDYFILE="$2"; shift 2 ;;
    -b|--backup-root) BACKUP_ROOT="$2"; shift 2 ;;
    -n|--keep)        KEEP_BACKUPS="$2"; shift 2 ;;
    --binary)         PREBUILT_BINARY="$2"; shift 2 ;;
    --skip-web)       SKIP_WEB=1; shift ;;
    --skip-tests)     SKIP_TESTS=1; shift ;;
    --rollback)       ROLLBACK=1; shift ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (try --help)" ;;
  esac
done

tmpdir="$(mktemp -d)"
ssh_pid=""
cleanup() {
  rm -rf "$tmpdir"
  [[ -n "$ssh_pid" ]] && kill "$ssh_pid" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- remote helper
cat > "$tmpdir/remote_body.sh" <<'REMOTE_BODY'
set -Eeuo pipefail
: "${REMOTE_BIN:?}"; : "${REMOTE_SERVICE:?}"; : "${REMOTE_CADDYFILE:?}"
: "${SERVICE_USER:=caddy}"; : "${BACKUP_ROOT:?}"; : "${STATE_FILE:?}"
: "${KEEP_BACKUPS:=5}"; : "${STAGED_BIN:=/tmp/sentra-caddy-new}"
: "${STAGED_CADDYFILE:=}"; : "${VALIDATE_ADMIN_LISTEN:=127.0.0.1:2021}"
: "${VALIDATE_DB:=/tmp/sentra-validate.db}"; : "${EXPECT_BIN_SHA:=}"
: "${EXPECT_ASSETS:=}"; : "${ADMIN_URL:=}"; : "${PROBE_HOSTS:=}"
: "${MODE:=deploy}"

log() { printf '  [remote] %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run_as_service_user() {
  if [[ "$SERVICE_USER" != root ]] && id "$SERVICE_USER" >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    sudo -u "$SERVICE_USER" "$@"
  else
    "$@"
  fi
}

restart_service() {
  systemctl restart "$REMOTE_SERVICE"
  sleep 3
  systemctl is-active --quiet "$REMOTE_SERVICE"
}

if [[ "$MODE" == rollback ]]; then
  last="$(cat "$STATE_FILE" 2>/dev/null || true)"
  [[ -n "$last" && -d "$last" ]] || fail "no previous deploy recorded in $STATE_FILE"
  mkdir -p "$BACKUP_ROOT"
  pre="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-pre-rollback"
  mkdir -p "$pre"
  cp -a "$REMOTE_BIN" "$pre/caddy" || fail "could not back up current binary"
  cp -a "$REMOTE_CADDYFILE" "$pre/Caddyfile" || fail "could not back up current Caddyfile"
  log "pre-rollback backup: $pre"
  install -m 0755 -o root -g root "$last/caddy" "$REMOTE_BIN"
  [[ -f "$last/Caddyfile" ]] && install -m 0644 -o root -g root "$last/Caddyfile" "$REMOTE_CADDYFILE"
  restart_service || fail "rollback restart failed"
  log "rolled back to $last"
  printf 'rolled_back_to=%s\n' "$last"
  exit 0
fi

# ---------------------------------------------------------------- validate
[[ -f "$STAGED_BIN" ]] || fail "staged binary missing: $STAGED_BIN"
if [[ -n "$EXPECT_BIN_SHA" ]]; then
  got="$(sha256sum "$STAGED_BIN" | cut -d' ' -f1)"
  [[ "$got" == "$EXPECT_BIN_SHA" ]] || fail "staged binary sha mismatch: $got != $EXPECT_BIN_SHA"
fi

validate_src="$REMOTE_CADDYFILE"
[[ -n "$STAGED_CADDYFILE" && -f "$STAGED_CADDYFILE" ]] && validate_src="$STAGED_CADDYFILE"
tmp_cfg="/tmp/sentra-validate.caddyfile"
awk -v p="$VALIDATE_ADMIN_LISTEN" -v db="$VALIDATE_DB" '
  /^[[:space:]]*admin_listen[[:space:]]/ { sub(/[^[:space:]]+[[:space:]]*$/, p) }
  /^[[:space:]]*db[[:space:]]/           { sub(/[^[:space:]]+[[:space:]]*$/, db) }
  { print }
' "$validate_src" > "$tmp_cfg"
rm -f "${VALIDATE_DB}"*
install -m 0755 -o root -g root "$STAGED_BIN" /usr/local/sbin/caddy-validate-tmp
if ! run_as_service_user /usr/local/sbin/caddy-validate-tmp validate --config "$tmp_cfg" >/tmp/sentra-validate.log 2>&1; then
  cat /tmp/sentra-validate.log >&2
  rm -f /usr/local/sbin/caddy-validate-tmp "$tmp_cfg" "${VALIDATE_DB}"*
  fail "caddy validate failed"
fi
log "validate OK"
rm -f /usr/local/sbin/caddy-validate-tmp "$tmp_cfg" "${VALIDATE_DB}"*

# ---------------------------------------------------------------- backup
ts="$(date +%Y%m%d-%H%M%S)"
bk="$BACKUP_ROOT/$ts"
mkdir -p "$bk"
cp -a "$REMOTE_BIN" "$bk/caddy" || fail "could not back up current binary"
cp -a "$REMOTE_CADDYFILE" "$bk/Caddyfile" || fail "could not back up current Caddyfile"
( cd "$bk" && sha256sum caddy Caddyfile > SHA256SUMS )
printf '%s\n' "$bk" > "$STATE_FILE"
log "backup: $bk"

restore_on_failure() {
  local rc=$?
  (( rc != 0 )) || return 0
  trap - EXIT
  log "deployment failed (exit $rc); restoring $bk"
  install -m 0755 -o root -g root "$bk/caddy" "$REMOTE_BIN"
  install -m 0644 -o root -g root "$bk/Caddyfile" "$REMOTE_CADDYFILE"
  restart_service || log "URGENT: rollback restart failed; inspect $REMOTE_SERVICE"
  exit "$rc"
}
# Cover explicit failures as well as commands that fail under set -e.
trap restore_on_failure EXIT

# ---------------------------------------------------------------- swap
install -m 0755 -o root -g root "$STAGED_BIN" "$REMOTE_BIN"
if [[ -n "$STAGED_CADDYFILE" && -f "$STAGED_CADDYFILE" ]]; then
  install -m 0644 -o root -g root "$STAGED_CADDYFILE" "$REMOTE_CADDYFILE"
  log "installed Caddyfile: $REMOTE_CADDYFILE"
fi
restart_service
log "service active (NRestarts=$(systemctl show "$REMOTE_SERVICE" -p NRestarts --value))"

# ---------------------------------------------------------------- verify
if [[ -n "$ADMIN_URL" ]]; then
  served="$(curl -s "$ADMIN_URL/" | grep -oE 'index-[A-Za-z0-9_-]+\.(js|css)' | sort -u | tr '\n' ' ')"
  log "served SPA assets: ${served:-<none>}"
  [[ -n "$served" ]] || fail "admin UI did not return a SPA shell at $ADMIN_URL/"
  for a in $EXPECT_ASSETS; do
    [[ "$served" == *"$a"* ]] || fail "admin UI does not reference expected asset $a"
    code="$(curl -s -o /dev/null -w '%{http_code}' "$ADMIN_URL/assets/$a")"
    [[ "$code" == 200 ]] || fail "asset $a -> HTTP $code"
    log "asset $a -> 200"
  done
fi

if [[ -n "$PROBE_HOSTS" ]]; then
  for h in $PROBE_HOSTS; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" \
      "http://127.0.0.1/?q=1%27%20union%20select%201--")"
    [[ "$code" == 403 ]] || fail "WAF probe for $h expected 403, got $code"
    log "WAF probe $h -> 403 (blocked)"
  done
fi

# ---------------------------------------------------------------- prune
if [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] && (( KEEP_BACKUPS > 0 )); then
  mapfile -t olds < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n "-$KEEP_BACKUPS")
  if (( ${#olds[@]} > 0 )); then
    rm -rf "${olds[@]}"
    log "pruned ${#olds[@]} old backup(s)"
  fi
fi

printf 'backup_dir=%s\n' "$bk"
printf 'binary_sha=%s\n' "$(sha256sum "$REMOTE_BIN" | cut -d' ' -f1)"
printf 'version=%s\n' "$("$REMOTE_BIN" version)"
REMOTE_BODY

# ---------------------------------------------------------------- local steps
command -v ssh  >/dev/null || die "ssh not found"
command -v scp  >/dev/null || die "scp not found"
[[ -d "$SENTRA_DIR" ]] || die "sentra checkout not found: $SENTRA_DIR"
[[ -n "$CADDYFILE" && ! -f "$CADDYFILE" ]] && die "caddyfile not found: $CADDYFILE"

if [[ "$ROLLBACK" == 1 ]]; then
  log "rolling back $HOST to the last deploy backup"
  if [[ "$ASSUME_YES" != 1 ]]; then
    read -r -p "Restore the last backup on $HOST and restart $REMOTE_SERVICE? [y/N] " ans
    case "$ans" in y|Y|yes|YES|Yes) ;; *) die "aborted" ;; esac
  fi
  cat > "$tmpdir/remote.sh" <<REMOTE_HEADER
export MODE='rollback'
export REMOTE_BIN='$REMOTE_BIN'
export REMOTE_SERVICE='$REMOTE_SERVICE'
export REMOTE_CADDYFILE='$REMOTE_CADDYFILE'
export SERVICE_USER='$SERVICE_USER'
export BACKUP_ROOT='$BACKUP_ROOT'
export STATE_FILE='$STATE_FILE'
REMOTE_HEADER
  cat "$tmpdir/remote_body.sh" >> "$tmpdir/remote.sh"
  scp -O -q "$tmpdir/remote.sh" "$HOST:/tmp/sentra-deploy-remote.sh"
  ssh "$HOST" "bash /tmp/sentra-deploy-remote.sh; rc=\$?; rm -f /tmp/sentra-deploy-remote.sh; exit \$rc"
  exit 0
fi

[[ "$SKIP_TESTS" == 1 ]] || command -v go >/dev/null || die "go not found"

out_bin="$tmpdir/caddy-${TARGET_OS}-${TARGET_ARCH}"
if [[ -n "$PREBUILT_BINARY" ]]; then
  [[ -f "$PREBUILT_BINARY" ]] || die "binary not found: $PREBUILT_BINARY"
  log "using prebuilt binary: $PREBUILT_BINARY"
  cp "$PREBUILT_BINARY" "$out_bin"
else
  command -v xcaddy >/dev/null || die "xcaddy not found"
  if [[ "$SKIP_WEB" == 1 ]]; then
    log "skipping SPA rebuild (--skip-web)"
  else
    log "building SPA (make web)"
    make -C "$SENTRA_DIR" web
  fi
  if [[ "$SKIP_TESTS" == 1 ]]; then
    log "skipping go tests (--skip-tests)"
  else
    log "running go tests"
    ( cd "$SENTRA_DIR" && go test ./... )
  fi
  log "building caddy $CADDY_VERSION for $TARGET_OS/$TARGET_ARCH"
  args=(build "$CADDY_VERSION")
  for m in "${MODULES[@]}"; do args+=(--with "$m"); done
  args+=(--output "$out_bin")
  ( cd "$SENTRA_DIR" && GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" CGO_ENABLED=0 xcaddy "${args[@]}" )
fi

bin_sha="$(shasum -a 256 "$out_bin" | cut -d' ' -f1)"
expect_assets=""
index_html="$SENTRA_DIR/web/dist/index.html"
[[ -f "$index_html" ]] && expect_assets="$(grep -oE 'index-[A-Za-z0-9_-]+\.(js|css)' "$index_html" | sort -u | tr '\n' ' ')"
log "binary sha256: $bin_sha"
[[ -n "$expect_assets" ]] && log "embedded SPA assets: $expect_assets"

log "uploading to $HOST"
scp -O -q "$out_bin" "$HOST:/tmp/sentra-caddy-new"
staged_caddyfile=""
if [[ -n "$CADDYFILE" ]]; then
  scp -O -q "$CADDYFILE" "$HOST:/tmp/sentra-caddyfile-new"
  staged_caddyfile="/tmp/sentra-caddyfile-new"
fi

if [[ "$ASSUME_YES" != 1 ]]; then
  read -r -p "Deploy $bin_sha to $HOST (restart $REMOTE_SERVICE)? [y/N] " ans
  case "$ans" in y|Y|yes|YES|Yes) ;; *) die "aborted" ;; esac
fi

# Build the env header for the remote helper. Values are single-quoted; paths
# and host lists here never contain a quote.
{
  printf 'export REMOTE_BIN=%q\n'        "$REMOTE_BIN"
  printf 'export REMOTE_SERVICE=%q\n'    "$REMOTE_SERVICE"
  printf 'export REMOTE_CADDYFILE=%q\n'  "$REMOTE_CADDYFILE"
  printf 'export SERVICE_USER=%q\n'      "$SERVICE_USER"
  printf 'export BACKUP_ROOT=%q\n'       "$BACKUP_ROOT"
  printf 'export STATE_FILE=%q\n'        "$STATE_FILE"
  printf 'export KEEP_BACKUPS=%q\n'      "$KEEP_BACKUPS"
  printf 'export STAGED_BIN=%q\n'        "/tmp/sentra-caddy-new"
  printf 'export STAGED_CADDYFILE=%q\n'  "$staged_caddyfile"
  printf 'export VALIDATE_ADMIN_LISTEN=%q\n' "$VALIDATE_ADMIN_LISTEN"
  printf 'export VALIDATE_DB=%q\n'       "$VALIDATE_DB"
  printf 'export EXPECT_BIN_SHA=%q\n'    "$bin_sha"
  printf 'export EXPECT_ASSETS=%q\n'     "$expect_assets"
  printf 'export ADMIN_URL=%q\n'         "$ADMIN_URL"
  printf 'export PROBE_HOSTS=%q\n'       "$PROBE_HOSTS"
  cat "$tmpdir/remote_body.sh"
} > "$tmpdir/remote.sh"
scp -O -q "$tmpdir/remote.sh" "$HOST:/tmp/sentra-deploy-remote.sh"

log "deploying on $HOST"
remote_out="$(ssh "$HOST" 'bash /tmp/sentra-deploy-remote.sh; rc=$?; rm -f /tmp/sentra-deploy-remote.sh /tmp/sentra-caddy-new /tmp/sentra-caddyfile-new; exit $rc')" || die "remote deploy failed"

echo
log "done"
printf '%s\n' "$remote_out" | sed 's/^/    /'
backup_dir="$(printf '%s\n' "$remote_out" | sed -n 's/^backup_dir=//p')"
if [[ -n "$backup_dir" ]]; then
  echo
  echo "Rollback:  scripts/deploy-sentra-caddy.sh --host $HOST --rollback"
  echo "  (or: ssh $HOST 'install -m0755 $backup_dir/caddy $REMOTE_BIN && systemctl restart $REMOTE_SERVICE')"
fi
