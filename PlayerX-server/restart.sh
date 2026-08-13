#!/bin/bash
clear
echo "[1/3] 正在关闭端口 2026 上的旧进程…"
lsof -ti :2026 | xargs kill 2>/dev/null
sleep 0.5
lsof -ti :2026 && echo "⚠️ 端口仍被占用"

echo "[2/3] 启动服务（后台守护）…"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

nohup node ./server.js > nohup.log 2>&1 &
disown

# 平台检测：Linux 用 eth1，macOS 用 en0
if [ "$(uname -s)" = "Darwin" ]; then
    LAN_IF="en0"
else
    LAN_IF="eth1"
fi
LAN_IP=$(ifconfig "$LAN_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}')

echo "[3/3] 等待服务就绪…"
for i in 1 2 3 4 5; do
    sleep 1
    if curl -s http://localhost:2026/ > /dev/null 2>&1; then
        echo ""
        echo "✅ PlayerX 服务已启动"
        echo "   Web 面板  : http://localhost:2026/"
        [ -n "$LAN_IP" ] && echo "   LAN 访问  : http://${LAN_IP}:2026/"
        exit 0
    fi
    echo "  等待中… (${i}/5)"
done
echo "⚠️ 服务可能尚未就绪，请检查 nohup.log"
