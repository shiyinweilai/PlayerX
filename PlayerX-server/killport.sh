#!/bin/bash
clear
echo "[1/3] 正在关闭端口 2026 上的旧进程…"
lsof -ti :2026 | xargs kill 2>/dev/null
sleep 0.5
lsof -ti :2026 && echo "⚠️ 端口仍被占用" || echo "✅ 端口已释放"

echo "[2/3] 启动服务（后台守护）…"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

nohup node ./server.js > nohup.log 2>&1 &
disown

# 探测 LAN IP（同 server.js 优先策略）
LAN_IP=$(ifconfig 2>/dev/null | awk '/inet / && !/127\.0\.0\.1|169\.254/ {
    ip=$2
    if (ip ~ /^192\.168\./)   rank=0
    else if (ip ~ /^10\./)    rank=1
    else if (ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) rank=2
    else rank=3
    printf "%d %s\n", rank, ip
}' | sort -n | head -1 | awk '{print $2}')

echo "[3/3] 等待服务就绪…"
for i in 1 2 3 4 5; do
    sleep 1
    if curl -s http://localhost:2026/ > /dev/null 2>&1; then
        echo "✅ PlayerX 服务已启动"
        echo "   Web 面板  : http://localhost:2026/"
        # 从 nohup.log 取 server 自己打出的真实 IP（比 awk 探测更可靠）
        LAN_URL=$(grep -m1 "LAN access" nohup.log | grep -oE 'https?://[0-9.]+:[0-9]+')
        [ -n "$LAN_URL" ] && echo "   LAN 访问  : ${LAN_URL}/"
        exit 0
    fi
    echo "  等待中… (${i}/5)"
done
echo "⚠️ 服务可能尚未就绪，请检查 nohup.log"
