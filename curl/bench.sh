#!/bin/sh
# ==============================================================================
# HTTP/3 性能对比：各 TLS 后端 curl 镜像 → 本地 caddy（h3net/172.28.99.10:8443）
# 指标：10MB 下载的 TTFB / 总耗时 / 吞吐；20 次小请求的 TTFB 均值
#   （小请求在同一进程内连续发出，首次含 QUIC 握手，其余复用连接）
# 用法：./bench.sh [runs]   （默认 3 次）
# 前置：caddy h3 server 在 h3net（见 build-all.sh test）
# 注：rustls 变体无 HTTP/3（ngtcp2 无 rustls 加密后端），不参与本对比
# ==============================================================================
set -eu
RUNS=${1:-3}

# 从 Dockerfile 读取 curl 版本，拼镜像名：curl:<curl版本>-h3-<变体>
cd "$(dirname "$0")"
CURL_VER=$(sed -n 's/^ARG CURL_VERSION=//p' Dockerfile-openssl | head -1)
IMAGE() { echo "curl:${CURL_VER}-h3-$1"; }

echo "== 10MB 下载（HTTP/3 only）=="
echo "variant     proto  ttfb_ms  total_ms  MB/s"
for v in openssl wolfssl gnutls awslc boringssl; do
  for i in $(seq 1 "$RUNS"); do
    docker run --rm --network h3net "$(IMAGE $v)" \
      curl --http3-only --resolve h3.local:8443:172.28.99.10 -k -s -o /dev/null \
      -w "$v   %{http_version}  %{time_starttransfer}  %{time_total}  %{speed_download}\n" \
      https://h3.local:8443/10mb.bin | awk -v v="$v" '{
        printf "%-11s %s  %6.0f  %8.0f  %7.1f\n", v, $2, $3*1000, $4*1000, $5/1048576
      }'
  done
done

echo ""
echo "== 小请求 TTFB（单进程 20 连发；first=含QUIC握手 rest=复用连接均值）=="
echo "variant     first_ms  rest_avg_ms"
for v in openssl wolfssl gnutls awslc boringssl; do
  docker image inspect "$(IMAGE $v)" >/dev/null 2>&1 || continue
  out=$(docker run --rm --network h3net "$(IMAGE $v)" sh -c "
    urls=''
    for i in \$(seq 1 20); do urls=\"\$urls https://h3.local:8443/\"; done
    curl --http3-only --resolve h3.local:8443:172.28.99.10 -k -s -o /dev/null \
      -w '%{time_starttransfer}\n' \$urls | awk '{
        n++
        if (n==1) f=\$1; else s+=\$1
      } END {printf \"%.1f %.1f\", f*1000, (s/(n-1))*1000}'")
  echo "$v   $out"
done
