#!/usr/bin/env bash
# 把 gate / txsp2 / alhk 的 Caddy 配置打包到本地 ~/Backups/caddy-configs/<时间戳>/
#
# 用法:
#   ./backup-caddy-configs.sh              # 备份全部主机
#   ./backup-caddy-configs.sh gate alhk    # 只备份指定主机
#   CADDY_BACKUP_DIR=/tmp/x ./backup-caddy-configs.sh
#   CADDY_BACKUP_KEEP=10 ./backup-caddy-configs.sh     # 只保留最近 10 份
#
# 说明:
#   - 打包的是整个 /etc/caddy（Caddyfile、waf 规则、blocks 片段、rule 目录等）。
#   - 明确排除 *.env（txsp2 的 cf.env 里有 Cloudflare API Token），凭据不进备份；
#     凭据的管理方式见 docs 里的说明，需要时单独恢复。
#   - 每台主机额外存一份文件清单和 caddy 版本号，便于恢复时核对。

set -euo pipefail

HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ]; then
  HOSTS=(gate txsp2 alhk)
fi

DEST="${CADDY_BACKUP_DIR:-$HOME/Backups/caddy-configs}"
KEEP="${CADDY_BACKUP_KEEP:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST/$STAMP"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

mkdir -p "$OUT"
echo "==> 输出目录: $OUT"

cleanup_on_error() {
  echo "!!! 备份失败，保留目录以便排查: $OUT" >&2
}
trap cleanup_on_error ERR

for host in "${HOSTS[@]}"; do
  echo "==> $host: 打包 /etc/caddy"
  # 远端 tar 直接流到本地，避免在服务器上写临时文件
  ssh "${SSH_OPTS[@]}" "$host" "tar -czf - -C /etc \
      --exclude='caddy/*.env' \
      --exclude='caddy/*/*.env' \
      --exclude='caddy/**/*.tmp' \
      caddy" >"$OUT/$host-etc-caddy.tar.gz"

  if ! tar -tzf "$OUT/$host-etc-caddy.tar.gz" >/dev/null 2>&1; then
    echo "!!! $host 的压缩包校验失败（文件损坏）" >&2
    exit 1
  fi

  ssh "${SSH_OPTS[@]}" "$host" "find /etc/caddy -type f ! -name '*.env' | sort" >"$OUT/$host-filelist.txt"
  ssh "${SSH_OPTS[@]}" "$host" 'caddy version 2>/dev/null | head -1' >"$OUT/$host-caddy-version.txt" || true

  files=$(tar -tzf "$OUT/$host-etc-caddy.tar.gz" | grep -c . || true)
  size=$(du -h "$OUT/$host-etc-caddy.tar.gz" | cut -f1)
  echo "    -> $host-etc-caddy.tar.gz ($size, $files 个条目)"
done

(
  cd "$OUT"
  shasum -a 256 ./*.tar.gz >SHA256SUMS 2>/dev/null || sha256sum ./*.tar.gz >SHA256SUMS
)

echo "==> 校验和:"
cat "$OUT/SHA256SUMS"

# 只保留最近 KEEP 份
if [ "$KEEP" -gt 0 ]; then
  ls -1dt "$DEST"/*/ 2>/dev/null | tail -n +$((KEEP + 1)) | while IFS= read -r path; do
    [ -n "$path" ] || continue
    echo "==> 清理旧备份: $path"
    rm -rf "$path"
  done
fi

echo "==> 完成。最近几份:"
ls -1dt "$DEST"/*/ 2>/dev/null | head -5
