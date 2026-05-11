#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n " && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "Arch: $(arch)"

# Simple helpers
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# Port helpers
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl wget
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl wget
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update && yum install -y cronie curl tar tzdata socat ca-certificates openssl wget
            else
                dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl wget
            fi
            ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm cronie curl tar tzdata socat ca-certificates openssl wget
            ;;
        alpine)
            apk update && apk add dcron curl tar tzdata socat ca-certificates openssl wget
            ;;
        *)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl wget
            ;;
    esac
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

install_acme() {
    echo -e "${green}Installing acme.sh for SSL certificate management...${plain}"
    cd ~ || return 1
    curl -s https://get.acme.sh | sh > /dev/null 2>&1
    return 0
}
setup_ssl_certificate() {
    local domain="$1"
    local server_ip="$2"
    local existing_port="$3"
    local existing_webBasePath="$4"

    echo -e "${green}Setting up SSL certificate...${plain}"

    # Check if acme.sh is installed
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${yellow}Failed to install acme.sh, skipping SSL setup${plain}"
            return 1
        fi
    fi

    # Create certificate directory
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"

    # Issue certificate
    echo -e "${green}Issuing SSL certificate for ${domain}...${plain}"
    echo -e "${yellow}Note: Port 80 must be open and accessible from the internet${plain}"

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport 80 --force

    if [ $? -ne 0 ]; then
        echo -e "${yellow}Failed to issue certificate for ${domain}${plain}"
        echo -e "${yellow}Please ensure port 80 is open and try again later with: x-ui${plain}"
        rm -rf ~/.acme.sh/${domain} 2> /dev/null
        rm -rf "$certPath" 2> /dev/null
        return 1
    fi

    # Install certificate
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem \
        --reloadcmd "systemctl restart x-ui" > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${yellow}Failed to install certificate${plain}"
        return 1
    fi

    # Enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # Set certificate for panel
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"

    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" > /dev/null 2>&1
        echo -e "${green}SSL certificate installed and configured successfully!${plain}"
        return 0
    else
        echo -e "${yellow}Certificate files not found${plain}"
        return 1
    fi
}

setup_ip_certificate() {
    local ipv4="$1"
    local ipv6="$2"

    echo -e "${green}Setting up Let's Encrypt IP certificate (shortlived profile)...${plain}"
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
    fi

    local certDir="/root/cert/ip"
    mkdir -p "$certDir"

    local domain_args="-d ${ipv4}"
    if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
        domain_args="${domain_args} -d ${ipv6}"
    fi

    local reloadCmd="systemctl restart x-ui 2>/dev/null || true"

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1
    ~/.acme.sh/acme.sh --issue ${domain_args} --standalone --server letsencrypt --certificate-profile shortlived --days 6 --httpport 80 --force

    if [ $? -ne 0 ]; then
        echo -e "${red}Failed to issue IP certificate${plain}"
        return 1
    fi

    ~/.acme.sh/acme.sh --installcert -d ${ipv4} \
        --key-file "${certDir}/privkey.pem" \
        --fullchain-file "${certDir}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    chmod 600 ${certDir}/privkey.pem 2> /dev/null
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"
    return 0
}

ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')

    local domain=""
    while true; do
        read -rp "Please enter your domain name: " domain
        domain="${domain// /}"
        if [[ -z "$domain" ]] || ! is_domain "$domain"; then
            echo -e "${red}Invalid domain format. Please try again.${plain}"
            continue
        fi
        break
    done
    
    SSL_ISSUED_DOMAIN="${domain}"
    setup_ssl_certificate "${domain}" "" "${existing_port}" "${existing_webBasePath}"
}
# 【關鍵修改：對接你的 GitHub 倉庫下載邏輯】
install_x-ui() {
    echo -e "${green}正在從你的 GitHub 倉庫下載 V2.9.4 私有版本...${plain}"
    
    # 指向你的專屬連結
    local tag_version="V2.9.4"
    local download_url="https://github.com/gyz767/x-ui-bin/releases/download/${tag_version}/x-ui-linux-amd64.tar.gz"

    if [[ -d "${xui_folder}" ]]; then
        rm -rf "${xui_folder}"
    fi
    mkdir -p "${xui_folder}"

    wget -N --no-check-certificate -O /tmp/x-ui-linux-amd64.tar.gz ${download_url}
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下載失敗！請確認你的 GitHub Release 連結是否正確且為公開狀態。${plain}"
        exit 1
    fi

    tar -zxvf /tmp/x-ui-linux-amd64.tar.gz -C /usr/local/
    cd ${xui_folder}
    chmod +x x-ui bin/xray-linux-amd64 x-ui.sh

    # 註冊系統服務 (Systemd)
    cat <<EOF > ${xui_service}/x-ui.service
[Unit]
Description=x-ui Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${xui_folder}
ExecStart=${xui_folder}/x-ui
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable x-ui
    systemctl restart x-ui
    
    # 設置快捷命令
    cp -f x-ui.sh /usr/bin/x-ui
    chmod +x /usr/bin/x-ui

    echo -e "${green}x-ui ${tag_version}${plain} 安裝完成，服務已啟動。"
}

# 完整的管理選單與執行流程
show_usage() {
    echo "x-ui 管理腳本使用方法: "
    echo "------------------------------------------"
    echo "x-ui              - 顯示管理選單 (核心功能)"
    echo "x-ui start        - 啟動 x-ui 面板"
    echo "x-ui stop         - 停止 x-ui 面板"
    echo "x-ui restart      - 重啟 x-ui 面板"
    echo "x-ui status       - 查看 x-ui 狀態"
    echo "x-ui enable       - 設置 x-ui 開機自啟"
    echo "x-ui disable      - 取消 x-ui 開機自啟"
    echo "x-ui log          - 查看 x-ui 日誌"
    echo "x-ui update       - 更新 x-ui 面板"
    echo "x-ui install      - 安裝 x-ui 面板"
    echo "x-ui uninstall    - 卸載 x-ui 面板"
    echo "------------------------------------------"
}

# 腳本執行入口
echo -e "${blue}正在執行一鍵安裝流程...${plain}"
install_base
install_x-ui
config_after_install

# 提示使用者 SSL 設定（可選）
read -rp "是否現在就要配置 SSL 證書？(y/n): " ssl_now
if [[ "${ssl_now}" == "y" || "${ssl_now}" == "Y" ]]; then
    server_ip=$(curl -s https://api4.ipify.org)
    prompt_and_setup_ssl "自行查看" "自行查看" "${server_ip}"
fi

echo -e "${green}所有流程已執行完畢。${plain}"
show_usage
