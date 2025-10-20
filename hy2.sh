#!/bin/bash
# Hysteria 2 自动部署脚本 (JSON配置版)

HY2_VERSION="v2.6.2"
# 多个SNI伪装域名选项
MASQ_DOMAINS=(
    "www.microsoft.com"
    "www.cloudflare.com" 
    "www.bing.com"
    "www.apple.com"
    "www.amazon.com"
    "www.wikipedia.org"
    "cdnjs.cloudflare.com"
    "cdn.jsdelivr.net"
    "static.cloudflareinsights.com"
    "www.speedtest.net"
)
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}
echo "🎯 随机选择SNI伪装域名: $MASQ_DOMAIN"

echo "🚀 Hysteria 2 自动部署（JSON配置版）"

# 强制用户输入端口（兼容Pterodactyl面板）
echo "⚠️  请在SSH终端或面板控制台输入端口号："

# 端口输入
while true; do
    echo "请输入端口号 (1024-65535):"
    read SERVER_PORT
    if [[ ! "$SERVER_PORT" =~ ^[0-9]+$ || "$SERVER_PORT" -lt 1024 || "$SERVER_PORT" -gt 65535 ]]; then
        echo "❌ 无效的端口号: $SERVER_PORT (必须是1024-65535)"
        continue
    fi
    break
done

# 自动生成复杂密码（避免特殊字符问题）
AUTH_PASSWORD=$(openssl rand -hex 16)
echo "🔑 自动生成密码: $AUTH_PASSWORD"
echo "⚠️ 请务必保存此密码，关闭终端后将无法找回"

echo "✅ 端口: $SERVER_PORT"
echo "✅ 密码: $AUTH_PASSWORD"

# 下载Hysteria二进制文件
function download_binary() {
    local os_name arch bin_name
    os_name=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os_name" in
        linux*) os_name="linux" ;;
        darwin*) os_name="darwin" ;;
        *) echo "不支持的操作系统: $os_name"; return 1 ;;
    esac
    
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "不支持的架构: $arch"; return 1 ;;
    esac
    
    bin_name="hysteria-$os_name-$arch"
    if [[ -f "$bin_name" ]]; then
        if [[ $(stat -c %Y "$bin_name") -lt $(date -d "1 week ago" +%s) ]]; then
            echo "🔄 二进制文件较旧，重新下载..."
            rm -f "$bin_name"
        else
            echo "✅ 使用现有二进制文件"
            return 0
        fi
    fi
    
    echo "📥 下载中..."
    local url="https://github.com/apernet/hysteria/releases/download/app/$HY2_VERSION/$bin_name"
    
    if command -v curl >/dev/null 2>&1; then
        curl -L --connect-timeout 30 -o "$bin_name" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget --timeout=30 -O "$bin_name" "$url" 2>/dev/null
    else
        echo "❌ 需要 curl 或 wget"
        return 1
    fi
    
    if [[ $? -eq 0 ]]; then
        chmod +x "$bin_name"
        echo "✅ 下载完成"
        return 0
    else
        echo "❌ 下载失败"
        return 1
    fi
}

# 生成自签名证书
function generate_certificate() {
    if [[ -f "c.pem" && -f "k.pem" ]]; then
        echo "✅ 证书已存在"
        return 0
    fi
    
    echo "🔐 生成优化版证书(ECDSA-P256)..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout k.pem -out c.pem -subj "/CN=localhost" -days 90 -nodes 2>/dev/null && \
    echo "✅ 证书生成完成（轻量级ECDSA，有效期90天）" || echo "❌ 证书生成失败"
}

# 生成JSON配置文件
function generate_config() {
    cat > server.json << EOF
{
    "listen": ":$SERVER_PORT",
    "tls": {
        "cert": "c.pem",
        "key": "k.pem",
        "alpn": ["h3"]
    },
    "auth": {
        "type": "password",
        "password": "$AUTH_PASSWORD"
    },
    "quic": {
        "max_idle_timeout": "20s",
        "keep_alive_period": "10s",
        "disable_path_mtu_discovery": false,
        "initial_stream_window_size": 4194304,
        "initial_connection_window_size": 8388608,
        "max_streams": 8,
        "handshake_timeout": "5s",
        "disable_stateless_reset": false,
        "initial_max_data": 4194304,
        "initial_max_stream_data": 2097152
    },
    "masquerade": {
        "type": "proxy",
        "proxy": {
            "url": "https://$MASQ_DOMAIN",
            "rewriteHost": true
        }
    }
}
EOF
    echo "✅ JSON配置已生成"
}

# 获取服务器IP
function get_server_ip() {
    local ip
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        ip=$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null)
    fi
    
    if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip"
    else
        echo "YOUR_SERVER_IP"
    fi
}

# 启动Hysteria服务
function start_service() {
    local os_name arch
    os_name=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os_name" in
        linux*) os_name="linux" ;;
        darwin*) os_name="darwin" ;;
        *) echo "不支持的操作系统: $os_name"; return 1 ;;
    esac
    
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "不支持的架构: $arch"; return 1 ;;
    esac
    
    local bin_name="hysteria-$os_name-$arch"
    
    echo -e "\n🔧 请选择运行模式:"
    select RUN_MODE in "前台运行(Pterodactyl)" "后台运行(独立服务器)"; do
        case $RUN_MODE in
            "前台运行(Pterodactyl)")
                echo "🚀 前台启动Hysteria 2服务..."
                ./$bin_name server -c server.json 2>&1 | tee hysteria.log | grep -v "debug"
                local pid=$!
                echo "✅ 服务运行中（PID: $pid）"
                echo "💡 停止服务需在面板操作或运行: kill -9 $pid"
                # 保持前台进程（Pterodactyl要求）
                tail -f /dev/null
                break
                ;;
            "后台运行(独立服务器)")
                echo "🚀 后台启动Hysteria 2服务..."
                ./$bin_name server -c server.json > hysteria.log 2>&1 &
                local pid=$!
                echo "✅ 服务已后台运行 (PID: $pid)"
                echo "管理命令:"
                echo "停止: kill -9 $pid"
                echo "日志: tail -f hysteria.log"
                break
                ;;
            *)
                echo "❌ 无效选项"
                ;;
        esac
    done
}

# 主函数
function main() {
    # 清理旧文件
    rm -f server.json c.pem k.pem
    
    download_binary || exit 1
    generate_certificate || {
        echo "❌ 证书生成失败，请检查OpenSSL是否正常工作"
        echo "💡 尝试手动运行以下命令："
        echo "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \\"
        echo "   -keyout k.pem -out c.pem -subj \"/CN=localhost\" -days 365 -nodes"
        exit 1
    }
    generate_config
    
    local server_ip=$(get_server_ip)
    
    echo ""
    echo "🎉 部署成功！"
    echo "🌐 服务器: $server_ip:$SERVER_PORT"
    echo "🔑 密码: $AUTH_PASSWORD"
    echo "🔓 模式: insecure（无需证书）"
    echo ""
    echo "========================================"
    echo "📱 v2rayN 链接:"
    echo "hysteria2://$AUTH_PASSWORD@$server_ip:$SERVER_PORT?sni=$MASQ_DOMAIN&alpn=h3&insecure=1#Hy2-JSON"
    echo ""
    echo "========================================"

    
    start_service
}

main