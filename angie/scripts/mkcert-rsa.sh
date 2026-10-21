#!/bin/sh
#
# OpenSSL RSA 证书一键生成脚本
# 证书层级: L1 root -> L2 intermediate -> L3 http-authority(Service CA) -> L4 hserver/hclient
# Subject 规范
# 使用 openssl x509 -req 方式签发, RSA 密钥 + SHA256 摘要
#
# 依赖: openssl (1.1.x 或 3.x)
# 用法: chmod +x mkcert.sh && ./mkcert.sh
#
# 兼容性: 纯 POSIX sh, 可用 bash / dash / busybox ash 运行
#
# 说明:
#   - cnf 配置由本脚本内嵌模板生成 (3 层 CA + 2 张实体证书), 已有 cnf 默认保留,
#     --reset-cnf 强制按模板重建
#   - subject / SAN 全部由顶部"配置变量"驱动: 拷贝本脚本到任意空目录,
#     改变量区即可生成对应证书 (无需准备任何 .cnf 文件)
#   - cleanup 会删除当前目录全部 *.key *.csr *.crt *.srl (保留 .cnf),
#     请在专用证书目录运行
#
set -e

# ============================================================
# 配置变量
# ============================================================

# openssl 命令路径 (可用环境变量覆盖)
OPENSSL=${OPENSSL:-openssl}

# DN 基础信息
C="CN"
ST="Xinjiang"
L="Urumqi"
O_ROOT="Test RSA"
OU_INTERMEDIATE="Intermediate Certificate Authority"
CN_INTERMEDIATE="Test RSA Intermediate CA"
OU_SERVICE="Service Certificate Authority"
CN_SERVICE="Test RSA Service CA"

# 实体 (http 链)
SERVER_CN="www.testrsa.selfsign"
CLIENT_CN="hclient.testrsa.selfsign"
# SAN
SAN_DNS="*.testrsa.selfsign localhost"
SAN_IPS="127.0.0.1"

# 密钥位数
RSA_BITS_CA=4096
RSA_BITS_ENTITY=2048

# 有效期（天）
DAYS_ROOT=3650
DAYS_INTERMEDIATE=1825
DAYS_AUTHORITY=1095
DAYS_ENTITY=365

# 是否强制重建 cnf (由 --reset-cnf 置位; 默认保留已有 cnf, 便于手改 SAN)
RESET_CNF=0

# ============================================================
# 颜色输出
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
success() { printf "${GREEN}[OK]${NC}   %s\n" "$1"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

# ============================================================
# 内嵌 cnf 模板 (自包含: 新环境无需预先准备 .cnf)
# 已有 cnf 默认保留, --reset-cnf 强制重建
# ============================================================

write_root_cnf() {
    [ -f root.cnf ] && [ "$RESET_CNF" -ne 1 ] && return 0
    cat > root.cnf <<EOF
# rsa-root.cnf (由 mkcert.sh 内嵌模板生成) — L1 根证书
# Subject: C=${C}, ST=${ST}, L=${L}, O=${O_ROOT}

[ req ]
default_bits        = ${RSA_BITS_CA}
default_md          = sha256
prompt              = no
distinguished_name  = req_distinguished_name
x509_extensions     = v3_ca

[ req_distinguished_name ]
C                   = ${C}
ST                  = ${ST}
L                   = ${L}
O                   = ${O_ROOT}

[ v3_ca ]
subjectKeyIdentifier   = hash
basicConstraints       = critical, CA:TRUE, pathlen:2
keyUsage               = critical, keyCertSign, cRLSign
EOF
    success "生成配置文件: root.cnf"
}

write_intermediate_cnf() {
    [ -f intermediate.cnf ] && [ "$RESET_CNF" -ne 1 ] && return 0
    cat > intermediate.cnf <<EOF
# rsa-intermediate.cnf (由 mkcert.sh 内嵌模板生成) — L2 中间证书
# Subject: C=${C}, ST=${ST}, L=${L}, O=${O_ROOT}, OU=${OU_INTERMEDIATE}, CN=${CN_INTERMEDIATE}

[ req ]
default_bits        = ${RSA_BITS_CA}
default_md          = sha256
prompt              = no
distinguished_name  = req_distinguished_name
x509_extensions     = v3_intermediate_ca

[ req_distinguished_name ]
C                   = ${C}
ST                  = ${ST}
L                   = ${L}
O                   = ${O_ROOT}
OU                  = ${OU_INTERMEDIATE}
CN                  = ${CN_INTERMEDIATE}

[ v3_intermediate_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE, pathlen:1
keyUsage               = critical, keyCertSign, cRLSign
extendedKeyUsage       = serverAuth, clientAuth
EOF
    success "生成配置文件: intermediate.cnf"
}

write_authority_cnf() {
    name="$1"
    cnf="${name}-authority.cnf"
    [ -f "$cnf" ] && [ "$RESET_CNF" -ne 1 ] && return 0
    cat > "$cnf" <<EOF
# rsa-${name}-authority.cnf (由 mkcert.sh 内嵌模板生成) — L3 服务证书 CA
# Subject: C=${C}, ST=${ST}, L=${L}, O=${O_ROOT}, OU=${OU_SERVICE}, CN=${CN_SERVICE}

[ req ]
default_bits        = ${RSA_BITS_CA}
default_md          = sha256
prompt              = no
distinguished_name  = req_distinguished_name
x509_extensions     = v3_service_ca

[ req_distinguished_name ]
C                   = ${C}
ST                  = ${ST}
L                   = ${L}
O                   = ${O_ROOT}
OU                  = ${OU_SERVICE}
CN                  = ${CN_SERVICE}

[ v3_service_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
extendedKeyUsage       = serverAuth, clientAuth
EOF
    success "生成配置文件: $cnf"
}

# 实体证书 cnf (hserver / hclient, 扩展段 v3_http_cert, 与 renew.sh 注册表一致).
write_entity_cnf() {
    ent="$1"      # 实体名: hserver 或 hclient
    role="$2"     # server 或 client
    cn="$3"       # CommonName

    cnf_file="${ent}.cnf"
    [ -f "$cnf_file" ] && [ "$RESET_CNF" -ne 1 ] && return 0
    eku="serverAuth"
    [ "$role" = "client" ] && eku="clientAuth"

    {
        printf '# %s  (由 mkcert.sh 内嵌模板生成, 可手改后重签)\n' "$cnf_file"
        cat <<EOF
[ req ]
default_bits        = ${RSA_BITS_ENTITY}
default_md          = sha256
prompt              = no
distinguished_name  = req_distinguished_name
req_extensions      = v3_req

[ req_distinguished_name ]
C                   = ${C}
ST                  = ${ST}
L                   = ${L}
O                   = ${O_ROOT}
CN                  = ${cn}

[ v3_req ]
basicConstraints    = CA:FALSE
subjectAltName      = @alt_names

[ alt_names ]
EOF
        n=1
        for d in $SAN_DNS; do
            printf 'DNS.%s = %s\n' "$n" "$d"; n=$((n+1))
        done
        n=1
        for ip in $SAN_IPS; do
            printf 'IP.%s = %s\n' "$n" "$ip"; n=$((n+1))
        done
        cat <<EOF

[ v3_http_cert ]
basicConstraints       = critical, CA:FALSE
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
keyUsage               = critical, digitalSignature, keyEncipherment
subjectAltName         = @alt_names
extendedKeyUsage       = $eku
EOF
    } > "$cnf_file"
    success "生成配置文件: $cnf_file"
}

# 落盘全部 cnf (3 个 CA + 2 张实体证书)
ensure_cnfs() {
    info "检查/生成 cnf 配置模板..."
    write_root_cnf
    write_intermediate_cnf
    write_authority_cnf "http"
    write_entity_cnf hserver server "$SERVER_CN"
    write_entity_cnf hclient client "$CLIENT_CN"
}

# ============================================================
# 环境检查
# ============================================================

check_env() {
    info "检查 OpenSSL 环境..."

    if ! command -v "$OPENSSL" >/dev/null 2>&1; then
        error "未找到 $OPENSSL 命令，请确认 OpenSSL 已安装并配置 PATH"
    fi

    version=$("$OPENSSL" version 2>&1 | head -1)
    success "OpenSSL 版本: $version"

    # 测试 RSA 密钥生成
    info "测试 RSA 算法支持..."
    "$OPENSSL" genrsa -out /tmp/openssl_test.key 2048 >/dev/null 2>&1 \
        || error "RSA 算法不支持，请检查 OpenSSL 安装"
    rm -f /tmp/openssl_test.key
    success "RSA 算法支持正常"
}

# ============================================================
# 清理旧文件 (删除全部旧证书/密钥/CSR/序列文件, 保留 .cnf 配置)
# ============================================================

cleanup() {
    info "清理旧的证书文件 (保留 .cnf 配置)..."
    rm -f *.key *.csr *.crt *.srl
    success "清理完成"
}

# ============================================================
# 生成 RSA 私钥
# ============================================================

gen_rsa_key() {
    outfile="$1"
    bits="${2:-2048}"
    "$OPENSSL" genrsa -out "$outfile" "$bits" >/dev/null
}

# ============================================================
# 第一层 (L1): 根证书 (root)
# ============================================================

gen_root() {
    info "========== L1: 生成根证书 (root) =========="

    subj="/C=${C}/ST=${ST}/L=${L}/O=${O_ROOT}"

    info "生成根证书私钥 (${RSA_BITS_CA}位)..."
    gen_rsa_key root.key "$RSA_BITS_CA"

    info "生成自签名根证书 (有效期 ${DAYS_ROOT} 天)..."
    "$OPENSSL" req -new -x509 -nodes -key root.key -sha256 -days "$DAYS_ROOT" \
        -out root.crt -config root.cnf -subj "$subj"

    success "根证书生成完成: root.crt"
}

# ============================================================
# 第二层 (L2): 中间证书 (intermediate)
# ============================================================

gen_intermediate() {
    info "========== L2: 生成中间证书 (intermediate) =========="

    subj="/C=${C}/ST=${ST}/L=${L}/O=${O_ROOT}/OU=${OU_INTERMEDIATE}/CN=${CN_INTERMEDIATE}"

    info "生成中间证书私钥 (${RSA_BITS_CA}位)..."
    gen_rsa_key intermediate.key "$RSA_BITS_CA"

    info "生成中间证书 CSR..."
    "$OPENSSL" req -config intermediate.cnf -new -key intermediate.key \
        -out intermediate.csr -sha256 -subj "$subj"

    info "使用根证书签发中间证书 (有效期 ${DAYS_INTERMEDIATE} 天)..."
    "$OPENSSL" x509 -req -in intermediate.csr -CA root.crt -CAkey root.key \
        -CAcreateserial -out intermediate.crt -days "$DAYS_INTERMEDIATE" -sha256 \
        -extfile intermediate.cnf -extensions v3_intermediate_ca

    success "中间证书生成完成: intermediate.crt"
}

# ============================================================
# 第三层 (L3): 服务证书 CA (http-authority = Service CA)
# ============================================================

gen_service_ca() {
    info "========== L3: 生成服务证书 CA (http-authority) =========="

    subj="/C=${C}/ST=${ST}/L=${L}/O=${O_ROOT}/OU=${OU_SERVICE}/CN=${CN_SERVICE}"

    info "生成 http-authority 私钥 (${RSA_BITS_CA}位)..."
    gen_rsa_key http-authority.key "$RSA_BITS_CA"

    info "生成 http-authority CSR..."
    "$OPENSSL" req -config http-authority.cnf -new -key http-authority.key \
        -out http-authority.csr -sha256 -subj "$subj"

    info "使用中间证书签发 Service CA (有效期 ${DAYS_AUTHORITY} 天)..."
    "$OPENSSL" x509 -req -in http-authority.csr -CA intermediate.crt -CAkey intermediate.key \
        -CAcreateserial -out http-authority.crt -days "$DAYS_AUTHORITY" -sha256 \
        -extfile http-authority.cnf -extensions v3_service_ca

    success "Service CA 生成完成: http-authority.crt"
}

# ============================================================
# 第四层 (L4): 实体证书
# ============================================================

gen_entity_cert() {
    cert_name="$1"     # 证书文件名前缀: hserver 或 hclient
    role="$2"          # server 或 client
    cn="$3"            # CommonName
    desc="$4"          # 描述

    cnf_file="${cert_name}.cnf"
    key_file="${cert_name}.key"
    csr_file="${cert_name}.csr"
    crt_file="${cert_name}.crt"

    subj="/C=${C}/ST=${ST}/L=${L}/O=${O_ROOT}/CN=${cn}"

    info "生成 ${desc} 私钥 (${RSA_BITS_ENTITY}位)..."
    gen_rsa_key "$key_file" "$RSA_BITS_ENTITY"

    info "生成 ${desc} CSR..."
    "$OPENSSL" req -config "$cnf_file" -new -key "$key_file" \
        -out "$csr_file" -sha256 -subj "$subj"

    info "使用 Service CA 签发 ${desc} (有效期 ${DAYS_ENTITY} 天)..."
    "$OPENSSL" x509 -req -in "$csr_file" \
        -CA http-authority.crt \
        -CAkey http-authority.key \
        -CAcreateserial -out "$crt_file" -days "$DAYS_ENTITY" -sha256 \
        -extfile "$cnf_file" -extensions v3_http_cert

    success "${desc} 生成完成: ${crt_file}"
}

# ============================================================
# 生成 L4 实体证书
# ============================================================

gen_http_certs() {
    info "========== L4: 生成 HTTP 实体证书 =========="

    # HTTP 服务器证书 (angie 使用)
    gen_entity_cert "hserver" "server" "$SERVER_CN" "HTTP服务器证书"
    # HTTP 客户端证书
    gen_entity_cert "hclient" "client" "$CLIENT_CN" "HTTP客户端证书"

    success "HTTP 实体证书全部生成完成"
}

# ============================================================
# 生成证书链文件
# ============================================================

gen_chains() {
    info "========== 生成证书链文件 =========="

    cat root.crt intermediate.crt > root-intermediate-chain.crt
    success "生成: root-intermediate-chain.crt"

    cat root.crt intermediate.crt http-authority.crt > http-full-chain.crt
    success "生成: http-full-chain.crt"

    cat hserver.crt http-authority.crt intermediate.crt > hserver-chain.crt
    success "生成: hserver-chain.crt"

    cat hclient.crt http-authority.crt intermediate.crt > hclient-chain.crt
    success "生成: hclient-chain.crt"
}

# ============================================================
# 验证证书链
# ============================================================

verify_one() {
    cafile="$1"
    cert="$2"
    desc="$3"

    if [ ! -f "$cert" ]; then
        warn "${desc}: 文件不存在，跳过"
        return
    fi

    if "$OPENSSL" verify -CAfile "$cafile" "$cert" >/dev/null 2>&1; then
        success "${desc}: OK"
        passed=$((passed+1))
    else
        warn "${desc}: FAILED"
        failed=$((failed+1))
    fi
}

verify_certs() {
    info "========== 验证证书链 =========="

    passed=0
    failed=0

    # 验证根证书（自签名）
    if "$OPENSSL" verify -CAfile root.crt root.crt >/dev/null 2>&1; then
        success "root (自签名): OK"
        passed=$((passed+1))
    else
        warn "root (自签名): FAILED"
        failed=$((failed+1))
    fi

    # 验证中间证书
    verify_one root.crt intermediate.crt "intermediate (由 root 签发)"

    # 验证服务 CA
    verify_one root-intermediate-chain.crt http-authority.crt "http-authority (Service CA)"

    # 验证实体证书
    verify_one http-full-chain.crt hserver.crt "hserver"
    verify_one http-full-chain.crt hclient.crt "hclient"

    echo ""
    info "验证结果: 通过 ${passed}, 失败 ${failed}"

    if [ "$failed" -gt 0 ]; then
        warn "有 ${failed} 个证书验证失败，请检查"
    else
        success "所有证书验证通过！"
    fi
}

# ============================================================
# 显示证书过期信息
# ============================================================

# openssl 风格的日期 "Sep 17 08:36:41 2027 GMT" -> "2027-09-17 08:36:41" (UTC)
# busybox date 无法直接解析 openssl enddate 格式, 手工转换
parse_openssl_date() {
    pod_month=$(printf '%s' "$1" | awk '{print $1}')
    pod_day=$(printf '%s' "$1" | awk '{print $2}')
    pod_time=$(printf '%s' "$1" | awk '{print $3}')
    pod_year=$(printf '%s' "$1" | awk '{print $4}')
    case "$pod_month" in
        Jan) pod_mn=01;; Feb) pod_mn=02;; Mar) pod_mn=03;; Apr) pod_mn=04;;
        May) pod_mn=05;; Jun) pod_mn=06;; Jul) pod_mn=07;; Aug) pod_mn=08;;
        Sep) pod_mn=09;; Oct) pod_mn=10;; Nov) pod_mn=11;; Dec) pod_mn=12;;
        *) return 1 ;;
    esac
    printf '%s-%s-%02d %s' "$pod_year" "$pod_mn" "$pod_day" "$pod_time"
}

show_cert_days() {
    cert="$1"
    desc="$2"

    [ -f "$cert" ] || return

    enddate=$("$OPENSSL" x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$enddate" ] || return

    end_norm=$(parse_openssl_date "$enddate") || return
    # openssl enddate 固定为 UTC 显示, 用 date -u 解析避免宿主 TZ 偏移
    end_epoch=$(date -u -d "$end_norm" +%s 2>/dev/null)

    [ -n "$end_epoch" ] || return
    now_epoch=$(date +%s)

    days_left=$(( (end_epoch - now_epoch) / 86400 ))
    if [ "$days_left" -lt 90 ]; then
        warn "${desc}: ${days_left} 天后过期 (${enddate})"
    else
        success "${desc}: ${days_left} 天后过期 (${enddate})"
    fi
}

show_expiry_info() {
    info "========== 证书有效期信息 =========="

    for cd_n in root intermediate http-authority hserver hclient; do
        show_cert_days "${cd_n}.crt" "$cd_n"
    done
}

# ============================================================
# 统计输出
# ============================================================

show_summary() {
    echo ""
    echo "============================================================"
    echo "  OpenSSL RSA 证书四层结构生成完成"
    echo "============================================================"
    echo ""
    echo "  证书层级结构:"
    echo "    L1 root (根CA, ${RSA_BITS_CA}位)"
    echo "    └── L2 intermediate (中间CA, ${RSA_BITS_CA}位)"
    echo "        └── L3 http-authority (Service CA, ${RSA_BITS_CA}位)"
    echo "            ├── L4 hserver.crt (angie 使用, ${RSA_BITS_ENTITY}位)"
    echo "            └── L4 hclient.crt (${RSA_BITS_ENTITY}位)"
    echo ""
    echo "  L4 SAN: $(echo $SAN_DNS | tr ' ' ', '),"
    echo "          $(echo $SAN_IPS | tr ' ' ', ')"
    echo ""

    key_count=$(ls *.key 2>/dev/null | wc -l)
    crt_count=$(ls *.crt 2>/dev/null | wc -l)
    cnf_count=$(ls *.cnf 2>/dev/null | wc -l)

    echo "  文件统计:"
    echo "    配置文件 (.cnf): ${cnf_count} 个"
    echo "    私钥文件 (.key): ${key_count} 个"
    echo "    证书文件 (.crt): ${crt_count} 个"
    echo ""
    echo "  算法: RSA (密钥) + SHA256 (摘要)"
    echo "  模式: 单证书 (签名和加密共用)"
    echo ""
    echo "============================================================"
}

# ============================================================
# 主流程
# ============================================================

main() {
    # 解析 --reset-cnf
    for arg in "$@"; do
        case "$arg" in
            --reset-cnf) RESET_CNF=1 ;;
            -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
            *) warn "未知参数: $arg (忽略)";;
        esac
    done

    echo ""
    echo "============================================================"
    echo "  OpenSSL RSA 证书四层结构一键生成脚本"
    echo "============================================================"
    echo ""

    # 1. 环境检查
    check_env

    # 2. 生成 cnf 配置模板
    ensure_cnfs

    # 3. 清理旧文件
    cleanup

    # 4. L1: 根证书
    gen_root

    # 5. L2: 中间证书
    gen_intermediate

    # 6. L3: 服务证书 CA
    gen_service_ca

    # 7. L4: 实体证书
    gen_http_certs

    # 8. 生成证书链
    gen_chains

    # 9. 验证证书链
    verify_certs

    # 10. 显示过期信息
    show_expiry_info

    # 11. 输出统计
    show_summary
}

# 执行主流程
main "$@"
