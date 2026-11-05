#!/usr/bin/env bash
# =============================================================================
# Q2TG 启动脚本（需要 root）
# 前置：已装 Docker；SnowLuma 已启动并登录 QQ；.env 已填好
#   TG_API_ID / TG_API_HASH / TG_BOT_TOKEN / POSTGRES_PASSWORD / ONEBOT_WS_TOKEN
#
# 用法：sudo bash run-q2tg.sh
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")/../deploy/q2tg"

log(){ printf '\033[1;32m[q2tg]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[q2tg][fail]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "必须 root：sudo bash $0"
command -v docker >/dev/null || die "未装 Docker，先跑 scripts/install-snowluma.sh"
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件"

[[ -f .env ]] || die "缺少 .env：cp .env.example .env 后填写 Telegram 凭据"
chmod 600 .env

# 校验必填项（空值会让 Q2TG 启动即退出，或连不上 Telegram / SnowLuma）
for k in TG_API_ID TG_API_HASH TG_BOT_TOKEN POSTGRES_PASSWORD ONEBOT_WS_TOKEN; do
  grep -qE "^${k}=.+" .env || die ".env 里 ${k} 未填写"
done
grep -qE '^TG_API_ID=[0-9]+$' .env || die "TG_API_ID 必须是纯数字"

# 共享网络与卷（SnowLuma 的 install 脚本会建；这里幂等兜底）
docker network create qq-bridge 2>/dev/null || true
docker volume create q2tg-cache 2>/dev/null || true
docker network inspect qq-bridge --format '{{range .Containers}}{{.Name}} {{end}}' \
  | grep -q snowluma || die "qq-bridge 里没有 snowluma：先启动 SnowLuma 并确认它加入了 qq-bridge 网络"

# 补丁是否已打（patched/index.js 由 patches/apply-q2tg-patches.py 生成）
[[ -f patched/index.js ]] || die "缺 patched/index.js：先按 patches/FIX-inlineDigitInput.md 导出 bundle 并打补丁"
node --check patched/index.js 2>/dev/null || die "patched/index.js 语法错误"

log "拉取镜像（ghcr.io；国内网络请先配镜像加速）..."
docker compose pull

log "启动 Postgres / q2tg ..."
docker compose up -d

log "等待 Q2TG 连上 SnowLuma..."
for i in $(seq 1 30); do
  docker compose logs --tail=200 q2tg 2>/dev/null | grep -qiE 'WS 连接成功' && break
  sleep 2
done

docker compose ps
echo
echo "=============== 下一步 ==============="
echo " 1) 在 Telegram 里找到你创建的 bot，发送 /setup 按提示完成配置"
echo " 2) 配置 UserBot 手机验证码时，必须点内联数字键盘按钮输入，直接打字会失效"
echo " 3) 实时日志：sudo docker compose logs -f q2tg"
echo " 4) Web 端口仅 127.0.0.1:8080；RichHeader / 合并转发查看器需要公网 HTTPS 域名，"
echo "    有域名后再加 nginx 反代并设置 .env 的 WEB_ENDPOINT"
echo "======================================"
