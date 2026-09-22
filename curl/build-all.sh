#!/bin/sh
# ==============================================================================
# curl 镜像构建与验证：
#   - 5 个 HTTP/3 变体（不同 TLS 后端）：openssl wolfssl gnutls awslc boringssl
#     镜像 curl:<curl版本>-h3-<变体>，容器内 curl -V 的 Features 含 HTTP3
#   - 1 个 Rustls 变体（无 HTTP/3，ngtcp2 没有 rustls 加密后端）：rustls
#     镜像 curl:<curl版本>-rustls，功能验证用 ./test-rustls.sh
#
# 用法：
#   ./build-all.sh            # 全部构建（buildx，带 buildkit 缓存）
#   ./build-all.sh openssl    # 只构建指定变体（可多次传参）
#   ./build-all.sh test       # 构建 + 起本地 caddy H3 server + 实测 --http3-only
#                             （rustls 变体不参与 H3 实测；构建后跑 ./test-rustls.sh）
#
# 说明：上游源码在 Dockerfile 内 wget 下载并 sha256 校验，
#       构建时不需要（也不应随仓库提供）src/ 目录，任何机器 clone 后直接构建。
# ==============================================================================
set -eu

cd "$(dirname "$0")"

VARIANTS="openssl wolfssl gnutls awslc boringssl rustls"
H3_VARIANTS="openssl wolfssl gnutls awslc boringssl"
ONLY=
DO_TEST=0

for a in "$@"; do
  case "$a" in
    test) DO_TEST=1 ;;
    openssl|wolfssl|gnutls|awslc|boringssl|rustls) ONLY="$ONLY $a" ;;
    *) echo "unknown arg: $a (expect: $VARIANTS | test)"; exit 1 ;;
  esac
done

if [ -z "$ONLY" ]; then
  ONLY=" $VARIANTS"
fi

# 从 Dockerfile 读取 curl 版本，拼镜像 tag：
#   h3 变体 → curl:<curl版本>-h3-<变体>；rustls 变体 → curl:<curl版本>-rustls
CURL_VER=$(sed -n 's/^ARG CURL_VERSION=//p' Dockerfile-openssl | head -1)
IMAGE() {
  if [ "$1" = "rustls" ]; then
    echo "curl:${CURL_VER}-rustls"
  else
    echo "curl:${CURL_VER}-h3-$1"
  fi
}

# ------------------------------------------------------------------------------
# 1) 构建
# ------------------------------------------------------------------------------
for v in $ONLY; do
  echo "==============================================================="
  echo ">>> build $(IMAGE "$v")"
  echo "==============================================================="
  docker buildx build \
    --load \
    -f "Dockerfile-$v" \
    -t "$(IMAGE "$v")" \
    .
done

# 若构建了 rustls 变体，提示其验证方式
for v in $ONLY; do
  [ "$v" = "rustls" ] && echo "提示：rustls 变体无 HTTP/3，功能验证用 ./test-rustls.sh"
done

# ------------------------------------------------------------------------------
# 2) 功能测试：本地 caddy 起 HTTP/3，各 h3 镜像 curl --http3-only 实测
#    网络 h3net（172.28.99.0/24）不存在时自动创建；rustls 变体不参与
# ------------------------------------------------------------------------------
if [ "$DO_TEST" = "1" ]; then
  docker network inspect h3net >/dev/null 2>&1 ||
    docker network create --subnet 172.28.99.0/24 h3net
  docker rm -f h3-caddy >/dev/null 2>&1 || true
  docker run -d --name h3-caddy --network h3net --ip 172.28.99.10 \
    -v "$(pwd)/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$(pwd)/caddy/cert:/srv/cert:ro" \
    -v "$(pwd)/caddy/www:/srv/www:ro" \
    caddy:2.11-alpine

  sleep 2
  # 只测 h3 变体（rustls 无 HTTP/3；用 --http3-only 会直接失败）
  for v in $H3_VARIANTS; do
    case " $ONLY " in *" $v "*) ;; *) continue ;; esac
    echo "--- curl:${CURL_VER}-h3-$v → http3 ---"
    docker run --rm --network h3net "curl:${CURL_VER}-h3-$v" \
      curl --http3-only --resolve "h3.local:8443:172.28.99.10" \
      -k -s -o /dev/null -w 'proto=%{http_version} code=%{http_code} ip=%{remote_ip}\n' \
      https://h3.local:8443/
  done
fi

echo "done."
