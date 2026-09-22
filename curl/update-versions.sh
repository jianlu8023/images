#!/usr/bin/env bash
# ==============================================================================
# update-versions.sh —— 更新指定上游组件的版本号 + sha256（6 个 Dockerfile 批量同步）
#
# 用法：
#   ./update-versions.sh <component> latest              # 自动解析最新官方版本
#   ./update-versions.sh <component> <version>           # 指定版本（如 8.23.0）
#   可选参数：
#     --dry-run    只解析版本/下载 tarball/计算 sha256 并打印改动计划，不写文件
#     --build      更新后立即 ./build-all.sh 构建受影响变体（验证新组合可编译）
#
# component 取值：
#   curl          → 同步改全部 6 个 Dockerfile（rustls 变体也含 curl）
#   nghttp3 | ngtcp2 → 改 5 个 HTTP/3 变体（rustls 变体不含，自动跳过）
#   openssl / wolfssl / gnutls / awslc / boringssl / rustls-ffi
#                               → 只改对应变体的 Dockerfile
#
# 行为：
#   1. latest：git ls-remote 解析上游 tag（gnutls 用 gnupg.org 官方 FTP 目录）；
#      openssl / gnutls 的 latest 限定在当前小版本系列内（如 3.5.x），避免直接跳大版本；
#      跨大版本请显式给版本号
#   2. 从官方源下载 tarball 到临时目录并计算 sha256（下载失败 = 版本不存在，不改文件）
#   3. 批量替换 Dockerfile：
#        - ARG <COMP>_VERSION / <COMP>_SHA256
#          （nghttp3/ngtcp2 首次更新时自动补加 _SHA256 ARG，
#           并把下载 RUN 里写死的 sha256 字面量改回 ${..._SHA256} 引用）
#        - 下载 URL 中写死的版本（curl release tag 的点→下划线、gnutls 版本系列目录）
#        - wolfssl tarball 文件名 / SRCDIR 中写死的版本统一改为 ${ARG} 引用
#   4. 打印 diff；未加 --build 时在交互终端询问是否构建
#
# 注意：
#   - 更新后务必 ./build-all.sh <变体> + ./build-all.sh test 验证；新版本可能
#     改变 configure 参数或依赖（踩坑记录见 HANDOFF.md 第 6 节）。
#   - 依赖本机可访问 github.com 与 www.gnupg.org。
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")"

ALL_FILES="Dockerfile-openssl Dockerfile-wolfssl Dockerfile-gnutls Dockerfile-awslc Dockerfile-boringssl Dockerfile-rustls"

# ------------------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------------------
COMP=
VER_SPEC=
DRY_RUN=0
DO_BUILD=0

for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --build)   DO_BUILD=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      if [ -z "$COMP" ]; then COMP=$a
      elif [ -z "$VER_SPEC" ]; then VER_SPEC=$a
      else echo "未知参数: $a（用法: $0 <component> [latest|version] [--dry-run] [--build]）" >&2; exit 1
      fi ;;
  esac
done

if [ -z "$COMP" ] || [ -z "$VER_SPEC" ]; then
  echo "用法: $0 <component> [latest|version] [--dry-run] [--build]" >&2
  echo "component: curl | nghttp3 | ngtcp2 | openssl | wolfssl | gnutls | awslc | boringssl | rustls-ffi" >&2
  exit 1
fi

case "$COMP" in
  curl|nghttp3|ngtcp2|openssl|wolfssl|gnutls|awslc|boringssl|rustls-ffi) ;;
  *) echo "未知组件: $COMP" >&2; exit 1 ;;
esac

# ------------------------------------------------------------------------------
# 上游 tag / 目录解析
# ------------------------------------------------------------------------------
git_tags() {  # $1=repo 路径，输出去 peel 后的 tag 名
  git ls-remote --tags "https://github.com/$1" 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/tags/||' | grep -vF '^{}'
}

latest_version() {
  local out= cur
  case "$COMP" in
    curl)      out=$(git_tags curl/curl    | grep -E '^curl-[0-9_]+$' | sed 's/^curl-//; s/_/./g' | sort -V | tail -1) ;;
    ngtcp2)    out=$(git_tags ngtcp2/ngtcp2   | grep -E '^v[0-9]+(\.[0-9]+)+$' | sed 's/^v//' | sort -V | tail -1) ;;
    nghttp3)   out=$(git_tags ngtcp2/nghttp3  | grep -E '^v[0-9]+(\.[0-9]+)+$' | sed 's/^v//' | sort -V | tail -1) ;;
    openssl)   cur=$(arg_value OPENSSL_VERSION Dockerfile-openssl)
      out=$(git_tags openssl/openssl | grep -E "^openssl-${cur%.*}\.[0-9]+$" | sed 's/^openssl-//' | sort -V | tail -1) ;;
    wolfssl)   out=$(git_tags wolfSSL/wolfssl | grep -E '^v[0-9]+(\.[0-9]+)+-stable$' | sort -V | tail -1) ;;
    awslc)     out=$(git_tags aws/aws-lc    | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -1) ;;
    boringssl) out=$(git_tags google/boringssl | grep -E '^0\.[0-9]{8}\.[0-9]+$' | sort -V | tail -1) ;;
    gnutls)    cur=$(arg_value GNUTLS_VERSION Dockerfile-gnutls)
      out=$(curl -fsSL --max-time 30 "https://www.gnupg.org/ftp/gcrypt/gnutls/v${cur%.*}/" \
        | grep -oE 'gnutls-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' | sed 's/^gnutls-//; s/\.tar\.xz$//' \
        | sort -V | tail -1) ;;
    rustls-ffi) out=$(git_tags rustls/rustls-ffi | grep -E '^v[0-9]+(\.[0-9]+)+$' | sed 's/^v//' | sort -V | tail -1) ;;
  esac
  [ -n "$out" ] || { echo "错误：无法解析 $COMP 的最新版本（网络异常？）" >&2; return 1; }
  echo "$out"
}

# 组件在当前 Dockerfile 里的 ARG 名 / 目标文件 / 构建变体名
arg_name() {
  case "$COMP" in
    curl) echo CURL ;; nghttp3) echo NGHTTP3 ;; ngtcp2) echo NGTCP2 ;; openssl) echo OPENSSL ;;
    wolfssl) echo WOLFSSL ;; gnutls) echo GNUTLS ;; awslc) echo AWSLC ;; boringssl) echo BORINGSSL ;;
    rustls-ffi) echo RUSTLS_FFI ;;
  esac
}

targets_for() {
  case "$COMP" in
    curl)       echo "$ALL_FILES" ;;                                   # 6 个 Dockerfile 均含 curl
    nghttp3|ngtcp2) echo "Dockerfile-openssl Dockerfile-wolfssl Dockerfile-gnutls Dockerfile-awslc Dockerfile-boringssl" ;;
    rustls-ffi) echo "Dockerfile-rustls" ;;                             # 组件名≠文件名
    *) echo "Dockerfile-$COMP" ;;
  esac
}

variants_for() {
  case "$COMP" in
    curl)       echo "openssl wolfssl gnutls awslc boringssl rustls" ;;
    nghttp3|ngtcp2) echo "openssl wolfssl gnutls awslc boringssl" ;;
    rustls-ffi) echo "rustls" ;;
    *) echo "$COMP" ;;
  esac
}

arg_value() {  # $1=ARG 名 $2=文件
  grep -oE "^ARG $1=[^ ]+" "$2" | head -1 | cut -d= -f2
}

# ------------------------------------------------------------------------------
# 版本规范化（写入 ARG 的形式与现有 Dockerfile 保持一致）
# ------------------------------------------------------------------------------
normalize_version() {
  local v=$1
  case "$COMP" in
    wolfssl)  v=${v#v}; v=${v%-stable}; echo "v${v}-stable" ;;   # tag 形如 v5.9.2-stable
    awslc)    echo "v${v#v}" ;;                                   # tag 形如 v5.9.0
    *)        echo "$v" ;;
  esac
}

# ------------------------------------------------------------------------------
# 官方源下载 URL
# ------------------------------------------------------------------------------
url_for() {  # $1=规范化版本
  local v=$1
  case "$COMP" in
    curl)      echo "https://github.com/curl/curl/releases/download/curl-${v//./_}/curl-$v.tar.xz" ;;
    nghttp3)   echo "https://github.com/ngtcp2/nghttp3/releases/download/v$v/nghttp3-$v.tar.gz" ;;
    ngtcp2)    echo "https://github.com/ngtcp2/ngtcp2/releases/download/v$v/ngtcp2-$v.tar.gz" ;;
    openssl)   echo "https://github.com/openssl/openssl/releases/download/openssl-$v/openssl-$v.tar.gz" ;;
    wolfssl)   echo "https://github.com/wolfSSL/wolfssl/archive/refs/tags/$v.tar.gz" ;;
    gnutls)    echo "https://www.gnupg.org/ftp/gcrypt/gnutls/v${v%.*}/gnutls-$v.tar.xz" ;;
    awslc)     echo "https://github.com/aws/aws-lc/archive/refs/tags/$v.tar.gz" ;;
    boringssl) echo "https://github.com/google/boringssl/archive/refs/tags/$v.tar.gz" ;;
    rustls-ffi) echo "https://github.com/rustls/rustls-ffi/archive/refs/tags/v$v.tar.gz" ;;
  esac
}

# ------------------------------------------------------------------------------
# 主流程
# ------------------------------------------------------------------------------
ARGNAME=$(arg_name)
FIRST_FILE=$(targets_for | awk '{print $1}')
CUR_VER=$(arg_value "${ARGNAME}_VERSION" "$FIRST_FILE")

if [ "$VER_SPEC" = "latest" ]; then
  RAW_VER=$(latest_version)
else
  RAW_VER=$VER_SPEC
fi
VER=$(normalize_version "$RAW_VER")

echo "== $COMP: 当前 $CUR_VER → 目标 $VER"

# 规范化后无变化则直接退出
case "$COMP" in
  wolfssl) CUR_NORM=$(normalize_version "$CUR_VER") ;;
  awslc)   CUR_NORM=$(normalize_version "$CUR_VER") ;;
  *)       CUR_NORM=$CUR_VER ;;
esac
if [ "$VER" = "$CUR_NORM" ]; then
  echo "已是最新版本，无需改动。"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bak"

URL=$(url_for "$VER")
TARBALL=$TMP/$(basename "$URL")
echo "-- 下载校验中：$URL"
if ! curl -fL --retry 2 --max-time 600 -o "$TARBALL" "$URL"; then
  echo "错误：下载失败（版本 $VER 可能不存在或 URL 规则有变），未改动任何文件。" >&2
  exit 1
fi
SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
echo "-- sha256: $SHA"
ls -lh "$TARBALL"

# ------------------------------------------------------------------------------
# 生成改动（--dry-run 时跳过写盘，只打印计划）
# ------------------------------------------------------------------------------
update_file() {  # $1=文件
  local f=$1
  cp "$f" "$TMP/bak/$f"
  case "$COMP" in
    curl)
      sed -E -i \
        -e "s|^ARG CURL_VERSION=.*|ARG CURL_VERSION=$VER|" \
        -e "s|^ARG CURL_SHA256=.*|ARG CURL_SHA256=$SHA|" \
        -e "s|releases/download/curl-[0-9_]+/|releases/download/curl-${VER//./_}/|" \
        -e 's|(&& echo ")[0-9a-f]{64}(  /curl-)|\1${CURL_SHA256}\2|' \
        "$f"
      ;;
    nghttp3)
      sed -E -i \
        -e "s|^ARG NGHTTP3_VERSION=.*|ARG NGHTTP3_VERSION=$VER|" \
        -e 's|(&& echo ")[0-9a-f]{64}(  /nghttp3-)|\1${NGHTTP3_SHA256}\2|' \
        "$f"
      if grep -q '^ARG NGHTTP3_SHA256=' "$f"; then
        sed -i "s|^ARG NGHTTP3_SHA256=.*|ARG NGHTTP3_SHA256=$SHA|" "$f"
      else
        sed -i "/^ARG NGHTTP3_VERSION=/a ARG NGHTTP3_SHA256=$SHA" "$f"
      fi
      ;;
    ngtcp2)
      sed -E -i \
        -e "s|^ARG NGTCP2_VERSION=.*|ARG NGTCP2_VERSION=$VER|" \
        -e 's|(&& echo ")[0-9a-f]{64}(  /ngtcp2-)|\1${NGTCP2_SHA256}\2|' \
        "$f"
      if grep -q '^ARG NGTCP2_SHA256=' "$f"; then
        sed -i "s|^ARG NGTCP2_SHA256=.*|ARG NGTCP2_SHA256=$SHA|" "$f"
      else
        sed -i "/^ARG NGTCP2_VERSION=/a ARG NGTCP2_SHA256=$SHA" "$f"
      fi
      ;;
    openssl)
      sed -i \
        -e "s|^ARG OPENSSL_VERSION=.*|ARG OPENSSL_VERSION=$VER|" \
        -e "s|^ARG OPENSSL_SHA256=.*|ARG OPENSSL_SHA256=$SHA|" \
        "$f"
      ;;
    wolfssl)
      sed -E -i \
        -e "s|^ARG WOLFSSL_VERSION=.*|ARG WOLFSSL_VERSION=$VER|" \
        -e "s|^ARG WOLFSSL_SHA256=.*|ARG WOLFSSL_SHA256=$SHA|" \
        -e 's|wolfssl-[0-9][0-9.]*(-stable)?\.tar\.gz|wolfssl-${WOLFSSL_VERSION#v}.tar.gz|g' \
        -e 's|WOLFSSL_SRCDIR=wolfssl-[0-9][0-9.]*(-stable)?|WOLFSSL_SRCDIR=wolfssl-${WOLFSSL_VERSION#v}|' \
        "$f"
      ;;
    gnutls)
      sed -i \
        -e "s|^ARG GNUTLS_VERSION=.*|ARG GNUTLS_VERSION=$VER|" \
        -e "s|^ARG GNUTLS_SHA256=.*|ARG GNUTLS_SHA256=$SHA|" \
        -e "s|gnutls/v[0-9][0-9.]*/|gnutls/v${VER%.*}/|" \
        "$f"
      ;;
    awslc)
      sed -i \
        -e "s|^ARG AWSLC_VERSION=.*|ARG AWSLC_VERSION=$VER|" \
        -e "s|^ARG AWSLC_SHA256=.*|ARG AWSLC_SHA256=$SHA|" \
        "$f"
      ;;
    boringssl)
      sed -i \
        -e "s|^ARG BORINGSSL_VERSION=.*|ARG BORINGSSL_VERSION=$VER|" \
        -e "s|^ARG BORINGSSL_SHA256=.*|ARG BORINGSSL_SHA256=$SHA|" \
        "$f"
      ;;
    rustls-ffi)
      sed -i \
        -e "s|^ARG RUSTLS_FFI_VERSION=.*|ARG RUSTLS_FFI_VERSION=$VER|" \
        -e "s|^ARG RUSTLS_FFI_SHA256=.*|ARG RUSTLS_FFI_SHA256=$SHA|" \
        "$f"
      ;;
  esac
}

echo
echo "== 改动计划："
for f in $(targets_for); do
  [ -f "$f" ] || { echo "错误：找不到 $f" >&2; exit 1; }
  echo "   - $f"
done

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "（--dry-run：未写盘。新版本 $VER，sha256 $SHA）"
  exit 0
fi

for f in $(targets_for); do
  update_file "$f"
done

echo
echo "== diff："
for f in $(targets_for); do
  diff -u "$TMP/bak/$f" "$f" | sed "s|^--- .*|--- $f (旧)|; s|^+++ .*|+++ $f (新)|" || true
done

# ------------------------------------------------------------------------------
# 可选：构建受影响变体
# ------------------------------------------------------------------------------
VARIANTS=$(variants_for)
BUILD=0
if [ "$DO_BUILD" = 1 ]; then
  BUILD=1
elif [ -t 0 ]; then
  printf '是否立即 ./build-all.sh %s 验证新组合？[y/N] ' "$VARIANTS"
  read -r ans || ans=N
  case "$ans" in y|Y|yes|YES) BUILD=1 ;; esac
fi

if [ "$BUILD" = 1 ]; then
  echo
  ./build-all.sh $VARIANTS
  echo
  echo "构建完成。建议再跑 ./build-all.sh test 实测 --http3-only。"
else
  echo
  echo "已更新文件。构建验证：./build-all.sh $VARIANTS   （再 ./build-all.sh test 实测）"
fi
