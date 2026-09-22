#!/bin/sh
# ==============================================================================
# Rustls 变体功能验证：起本地 caddy TLS 服务（与 H3 变体共用 caddy/cert 证书），
# 实测 https 请求，并校验 Rustls 后端已生效。
#
# 用法：./test-rustls.sh
# 镜像：curl:<curl版本>-rustls（不含 HTTP/3，见 Dockerfile-rustls 说明）
# 说明：rustls 信任系统 CA（构建时 --with-ca-bundle），因此用 caddy 自签证书
#       必须 -k（或临时挂载 CA），与 H3 变体测试口径一致
# ==============================================================================
set -eu

cd "$(dirname "$0")"
CURL_VER=$(sed -n 's/^ARG CURL_VERSION=//p' Dockerfile-rustls | head -1)
IMAGE="curl:${CURL_VER}-rustls"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "镜像 $IMAGE 不存在，先执行：./build-all.sh rustls" >&2
  exit 1
fi

# 1) 镜像内容自检：Rustls 生效、无 HTTP/3、全功能在
echo "== curl -V 自检 =="
docker run --rm "$IMAGE" sh -c '
  curl -V
  echo ---
  curl -V | grep -q "Rustls"   && echo "OK: Rustls backend"
  curl -V | grep -q "HTTP3"    && { echo "FAIL: 不应有 HTTP3"; exit 1; } || echo "OK: 无 HTTP3（预期）"
  curl -V | grep -q "brotli/"  && curl -V | grep -q "zstd/" && curl -V | grep -q "libssh/" \
    && curl -V | grep -q "libidn2/" && curl -V | grep -q "libpsl/" \
    && curl -V | grep -q "GSS-API" && curl -V | grep -q "NTLM" \
    && curl -V | grep -q "smb" && echo "OK: 全功能齐"
'

# 2) 起 caddy TLS 服务（h3net/172.28.99.10，与 build-all.sh test 同环境）
docker network inspect h3net >/dev/null 2>&1 ||
  docker network create --subnet 172.28.99.0/24 h3net
docker rm -f h3-caddy >/dev/null 2>&1 || true
docker run -d --name h3-caddy --network h3net --ip 172.28.99.10 \
  -v "$(pwd)/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$(pwd)/caddy/cert:/srv/cert:ro" \
  -v "$(pwd)/caddy/www:/srv/www:ro" \
  caddy:2.11-alpine

sleep 2
trap 'docker rm -f h3-caddy >/dev/null 2>&1 || true' EXIT

# 3) 实测 https（TLS 由 rustls 完成；自签证书用 -k）
echo "== https 实测（rustls TLS）=="
for i in 1 2 3; do
  docker run --rm --network h3net "$IMAGE" \
    curl -k -s -o /dev/null \
    -w 'code=%{http_code} ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
    --resolve "h3.local:8443:172.28.99.10" https://h3.local:8443/
done

# 4) HTTP/2 协商确认（ALPN h2）
echo "== ALPN 协商 =="
docker run --rm --network h3net "$IMAGE" \
  curl -k -s -o /dev/null \
  -w 'http2? code=%{http_version} http_version=%{http_version}\n' \
  --resolve "h3.local:8443:172.28.99.10" https://h3.local:8443/

# 5) 信任 CA 验证（不加 -k，挂载自签根证书为系统 CA）
echo "== 信任系统 CA 验证（不加 -k）=="
docker run --rm --network h3net \
  -v "$(pwd)/caddy/cert/cert.pem:/usr/local/share/ca-certificates/h3test.crt:ro" \
  "$IMAGE" sh -c '
    cp /usr/local/share/ca-certificates/h3test.crt /etc/ssl/certs/ca-certificates.crt
    curl -s -o /dev/null -w "CA验证 code=%{http_code}\n" \
      --resolve "h3.local:8443:172.28.99.10" https://h3.local:8443/
  '

echo "test-rustls: done."
