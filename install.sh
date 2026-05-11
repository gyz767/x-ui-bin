#!/bin/bash

# 定义版本和下载链接（用你刚才生成的 Release 链接）
URL="https://github.com/gyz767/x-ui-bin/releases/download/V2.9.4/x-ui-linux-amd64.tar.gz"

echo "正在从个人仓库下载 x-ui..."
wget -N --no-check-certificate -O /tmp/x-ui-linux-amd64.tar.gz ${URL}

echo "正在解压..."
mkdir -p /usr/local/x-ui
tar -zxvf /tmp/x-ui-linux-amd64.tar.gz -C /usr/local/

echo "设置权限..."
chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-amd64

echo "安装完成！请输入 /usr/local/x-ui/x-ui 启动。"
