#!/bin/bash

# ================== 端口设置 ==================
# 环境变量没填时，使用默认值防止脚本报错
export TUIC_PORT=${TUIC_PORT:-""}       
export HY2_PORT=${HY2_PORT:-""}         
export REALITY_PORT=${REALITY_PORT:-""} 
# ==============================================

cd "$(dirname "$0")"
export FILE_PATH="${PWD}/.npm"
export DATA_PATH="${PWD}/singbox_data"
mkdir -p "$FILE_PATH" "$DATA_PATH"
export XDG_DATA_HOME="/tmp/.singbox_data"
export XDG_CACHE_HOME="/tmp/.singbox_cache"
export TMPDIR="/tmp"
rm -rf "${FILE_PATH}"/sb_* ~/.npm/_logs/* ./npm-debug.log* "${DATA_PATH}"/* /tmp/.singbox_* 2>/dev/null || true

# ---------- UUID 处理 ----------
UUID_FILE="${FILE_PATH}/uuid.txt"
if [ -f "$UUID_FILE" ]; then
  UUID=$(cat "$UUID_FILE")
  echo -e "\e[1;33m[UUID] 复用固定 UUID: $UUID\e[0m"
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "$UUID" > "$UUID_FILE"
  chmod 600 "$UUID_FILE"
  echo -e "\e[1;32m[UUID] 首次生成并永久保存: $UUID\e[0m"
fi

[ ! -d "${FILE_PATH}" ] && mkdir -p "${FILE_PATH}"

# ---------- 获取 Sing-box 版本 ----------
SINGBOX_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
if [ -z "$SINGBOX_VER" ]; then
  SINGBOX_VER="1.11.4"
fi

ARCH=$(uname -m)
DOWNLOAD_URL=""

if [[ "$ARCH" == "arm"* ]] || [[ "$ARCH" == "aarch64" ]]; then
  DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-arm64.tar.gz"
elif [[ "$ARCH" == "amd64"* ]] || [[ "$ARCH" == "x86_64" ]]; then
  DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-amd64.tar.gz"
elif [[ "$ARCH" == "s390x" ]]; then
  DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/sing-box-${SINGBOX_VER}-linux-s390x.tar.gz"
else
  echo "不支持的架构: $ARCH"
  exit 1
fi

download_file() {
  local URL=$1
  local FILENAME=$2
  if command -v curl >/dev/null 2>&1; then
    curl -L -sS -o "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (curl)\e[0m"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (wget)\e[0m"
  else
    echo -e "\e[1;31m未找到 curl 或 wget\e[0m"
    exit 1
  fi
}

# ---------- 下载核心 ----------
SINGBOX_BIN="${FILE_PATH}/sb_core"
if [ ! -f "$SINGBOX_BIN" ]; then
  echo -e "\e[1;33m[下载] 未检测到 Sing-box 核心，正在下载 v${SINGBOX_VER}...\e[0m"
  download_file "$DOWNLOAD_URL" "${FILE_PATH}/singbox.tar.gz"
  tar -zxvf "${FILE_PATH}/singbox.tar.gz" -C "${FILE_PATH}" --strip-components=1 "sing-box-${SINGBOX_VER}-linux-"*/sing-box >/dev/null 2>&1 || \
  tar -zxvf "${FILE_PATH}/singbox.tar.gz" -C "${FILE_PATH}" --wildcards "*/sing-box" --strip-components=1 >/dev/null 2>&1
  mv "${FILE_PATH}/sing-box" "$SINGBOX_BIN" 2>/dev/null || true
  rm -f "${FILE_PATH}/singbox.tar.gz"
  chmod +x "$SINGBOX_BIN"
else
  echo -e "\e[1;32m[核心] 已存在 Sing-box 核心，跳过下载\e[0m"
fi

# ---------- 生成 Reality 密钥 ----------
if [ "$REALITY_PORT" != "" ] && [ "$REALITY_PORT" != "0" ]; then
  KEY_FILE="${FILE_PATH}/key.txt"
  if [ -f "$KEY_FILE" ]; then
    echo -e "\e[1;33m[密钥] 检测到已有密钥，复用...\e[0m"
    private_key=$(grep "PrivateKey:" "$KEY_FILE" | awk '{print $2}')
    public_key=$(grep "PublicKey:" "$KEY_FILE" | awk '{print $2}')
  else
    echo -e "\e[1;33m[密钥] 首次生成 Reality 密钥对...\e[0m"
    output=$("$SINGBOX_BIN" generate reality-keypair)
    echo "$output" > "$KEY_FILE"
    private_key=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$output" | awk '/PublicKey:/ {print $2}')
    chmod 600 "$KEY_FILE"
    echo -e "\e[1;32m[密钥] 密钥已保存，重启后保持不变\e[0m"
  fi
fi

# ---------- 生成通用自签证书 (带 SAN) ----------
if [ -f "${FILE_PATH}/cert.pem" ] && command -v openssl >/dev/null 2>&1; then
  if ! openssl x509 -in "${FILE_PATH}/cert.pem" -noout -text 2>/dev/null | grep -q "DNS:www.bing.com"; then
    echo -e "\e[1;33m[证书] 检测到旧版无 SAN 证书，重新生成...\e[0m"
    rm -f "${FILE_PATH}/cert.pem" "${FILE_PATH}/private.key"
  fi
fi

if [ ! -f "${FILE_PATH}/cert.pem" ] || [ ! -f "${FILE_PATH}/private.key" ]; then
  if command -v openssl >/dev/null 2>&1; then
    echo -e "\e[1;33m[证书] 生成通用自签证书（含 SAN）...\e[0m"
    openssl genrsa -out "${FILE_PATH}/private.key" 2048 2>/dev/null
    cat > "${FILE_PATH}/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = www.bing.com
[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
DNS.1 = www.bing.com
DNS.2 = bing.com
EOF
    openssl req -new -x509 -days 3650 -key "${FILE_PATH}/private.key" -out "${FILE_PATH}/cert.pem" -config "${FILE_PATH}/openssl.cnf" 2>/dev/null
    echo -e "\e[1;32m[证书] 已生成：CN=www.bing.com，SAN=www.bing.com\e[0m"
  else
    echo -e "\e[1;31m[警告] 环境无 openssl，将使用硬编码备用证书！\e[0m"
    cat > "${FILE_PATH}/private.key" <<'EOF'
-----BEGIN EC PARAMETERS-----
BgqghkjOPQQBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/+siNnfBYsdUYsAoGCCqGSM49
AwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASAnngZreoQDF16ARa
/TsyLyFoPkhTxSbehH/OBEjHtSZGaDhMqQ==
-----END EC PRIVATE KEY-----
EOF
    cat > "${FILE_PATH}/cert.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
MIIBejCCASGgAwIBAgIUFWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwMTAxMDEwMTAwWhcNMzUwMTAxMDEw
MTAwWjATMREwDwYDVQQDDAhiaW5nLmNvbTBNBgqgGzM9AgEGCCqGSM49AwEHA0IA
BNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgDZ54Ga3qEAxdeWv07Mi8hd5IR8Um
3oR/zQRIx7UmRmg4TKmjUzBRMB0GA1UdDgQWBQTV1cFID7UISE7PLTBRBfGbgrkM
NzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgrkMNzAPBgNVHRMBAf8EBTAD
AQH/MAoGCCqGSM49BAMCA0cAMEQCIARDAJvg0vd/ytrQVvEcSm6XTlB+eQ6OFb9L
bLYL9Zi+AiffoMbi4y/0YUQlTtz7as9S8/lciBF5VCUoVIKS+vX2g==
-----END CERTIFICATE-----
EOF
  fi
  chmod 600 "${FILE_PATH}/private.key"
fi

# ---------- 计算证书的纯十六进制指纹 (SHA-256) ----------
CERT_HEX=""
if command -v openssl >/dev/null 2>&1; then
  CERT_HEX=$(openssl x509 -in "${FILE_PATH}/cert.pem" -outform der 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')
fi

# ---------- 生成配置 ----------
INBOUNDS=()

if [ -n "$TUIC_PORT" ] && [ "$TUIC_PORT" != "0" ]; then
  INBOUNDS+=("{
    \"type\": \"tuic\",
    \"listen\": \"::\",
    \"listen_port\": $TUIC_PORT,
    \"users\": [{\"uuid\": \"$UUID\", \"password\": \"admin\"}],
    \"congestion_control\": \"bbr\",
    \"tls\": {\"enabled\": true, \"alpn\": [\"h3\"], \"certificate_path\": \"${FILE_PATH}/cert.pem\", \"key_path\": \"${FILE_PATH}/private.key\"}
  }")
fi

if [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
  INBOUNDS+=("{
    \"type\": \"hysteria2\",
    \"listen\": \"::\",
    \"listen_port\": $HY2_PORT,
    \"users\": [{\"password\": \"$UUID\"}],
    \"masquerade\": \"https://bing.com\",
    \"tls\": {\"enabled\": true, \"alpn\": [\"h3\"], \"certificate_path\": \"${FILE_PATH}/cert.pem\", \"key_path\": \"${FILE_PATH}/private.key\"}
  }")
fi

if [ -n "$REALITY_PORT" ] && [ "$REALITY_PORT" != "0" ]; then
  INBOUNDS+=("{
    \"type\": \"vless\",
    \"listen\": \"::\",
    \"listen_port\": $REALITY_PORT,
    \"users\": [{\"uuid\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"}],
    \"tls\": {
      \"enabled\": true,
      \"server_name\": \"www.nazhumi.com\",
      \"reality\": {
        \"enabled\": true,
        \"handshake\": {\"server\": \"www.nazhumi.com\", \"server_port\": 443},
        \"private_key\": \"$private_key\",
        \"short_id\": [\"\"]
      }
    }
  }")
fi

IFS=','
cat > "${FILE_PATH}/config.json" <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    ${INBOUNDS[*]}
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

# ---------- 启动 Sing-box ----------
"$SINGBOX_BIN" run -c "${FILE_PATH}/config.json" >/dev/null 2>&1 &
SINGBOX_PID=$!
echo "[SING-BOX] 启动完成 PID=$SINGBOX_PID"

# ---------- 获取 IP 与 生成订阅 ----------
IP=$(curl -s --max-time 3 ipv4.ip.sb || curl -s --max-time 2 api.ipify.org || echo "IP_ERROR")

> "${FILE_PATH}/list.txt"

# 使用 pinSHA256 传入十六进制指纹，并去除 insecure 参数
if [ -n "$TUIC_PORT" ] && [ "$TUIC_PORT" != "0" ]; then
  echo "tuic://${UUID}:admin@${IP}:${TUIC_PORT}?sni=www.bing.com&alpn=h3&congestion_control=bbr${CERT_HEX:+&pinSHA256=${CERT_HEX}}#tuic_easyshare" >> "${FILE_PATH}/list.txt"
fi

if [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
  echo "hysteria2://${UUID}@${IP}:${HY2_PORT}/?sni=www.bing.com${CERT_HEX:+&pinSHA256=${CERT_HEX}}#hy2_easyshare" >> "${FILE_PATH}/list.txt"
fi

if [ -n "$REALITY_PORT" ] && [ "$REALITY_PORT" != "0" ]; then
  echo "vless://${UUID}@${IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.nazhumi.com&fp=firefox&pbk=${public_key}&type=tcp#reality_easyshare" >> "${FILE_PATH}/list.txt"
fi

base64 "${FILE_PATH}/list.txt" | tr -d '\n' > "${FILE_PATH}/sub.txt"
echo -e "\e[1;32m====== 订阅链接 (list.txt) ======\e[0m"
cat "${FILE_PATH}/list.txt"
echo -e "\n\e[1;32m[成功] ${FILE_PATH}/sub.txt 已保存\e[0m"

# ---------- 定时重启逻辑 ----------
schedule_restart() {
  echo "[定时重启:Sing-box] 已启动（北京时间 00:03）"
  LAST_RESTART_DAY=-1

  while true; do
    now_ts=$(date +%s)
    beijing_ts=$((now_ts + 28800))
    H=$(( (beijing_ts / 3600) % 24 ))
    M=$(( (beijing_ts / 60) % 60 ))
    D=$(( beijing_ts / 86400 ))

    if [ "$H" -eq 0 ] && [ "$M" -eq 3 ] && [ "$D" -ne "$LAST_RESTART_DAY" ]; then
      echo "[定时重启:Sing-box] 到达 00:03 → 重启 sing-box"
      LAST_RESTART_DAY=$D

      kill "$SINGBOX_PID" 2>/dev/null || true
      sleep 3
      rm -rf ~/.npm/_logs/* ./npm-debug.log* "${DATA_PATH}"/* /tmp/.singbox_* 2>/dev/null || true

      "$SINGBOX_BIN" run -c "${FILE_PATH}/config.json" >/dev/null 2>&1 &
      SINGBOX_PID=$!
      echo "[Sing-box重启完成] 新 PID: $SINGBOX_PID"
    fi
    sleep 30
  done
}

schedule_restart
