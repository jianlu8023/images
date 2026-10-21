#!/bin/sh
#
# 铜锁国密 SM2 证书生成脚本
# 证书层级: L1 root -> L2 intermediate -> L3 http-authority(Service CA) -> L4 hserver/hclient 双证书 + hserver 单证书(RFC8998)
# Subject 规范见
# 使用铜锁 ca 命令方式签发, SM2 密钥 + SM3 摘要, 强制 SM2 标识 1234567812345678
#
# 依赖: tongsuo 8.x (TONGSUO_BIN 可覆盖)
# 用法: ./mkcert.sh
#
# 兼容性: 纯 POSIX sh, 可用 bash / dash / busybox ash 运行
#
# 说明:
#   - cnf 配置由本脚本内嵌模板生成 (CA 层 + 4 张实体双证书), 已有 cnf 默认保留,
#     --reset-cnf 强制按模板重建
#   - 签发使用 x509 -req -CAcreateserial 方式: Tongsuo 8.5.0 (OpenSSL 3.5.4)
#     已正确支持 (首次随机 serial 写入 <CA>.srl, 后续自增); Tongsuo 8.4.0 /
#     OpenSSL 3.0.x 会无条件预填随机 serial、-CAcreateserial 被静默忽略
#   - 双证书模式: sign = digitalSignature (握手签名), enc = keyAgreement/keyEncipherment (密钥传输)

set -e

# ============================================================
# 配置变量
# ============================================================

# 铜锁命令 (可用环境变量覆盖)
TONGSUO_BIN=${TONGSUO_BIN:-/usr/local/tongsuo/bin/tongsuo}

# SM2 签名者标识 (GM/T 标准值; ca 的 CSR 自签校验只认该默认值, 不可修改)
SM2_ID=${SM2_ID:-1234567812345678}

# DN 基础信息
C="CN"
ST="Xinjiang"
L="Urumqi"
O_ROOT="Test SM2"
OU_INTERMEDIATE="Intermediate Certificate Authority"
CN_INTERMEDIATE="Test SM2 Intermediate CA"
OU_SERVICE="Service Certificate Authority"
CN_SERVICE="Test SM2 Service CA"

# 实体 (http 链)
SERVER_CN="www.testsm2.selfsign"
CLIENT_CN="hclient.testsm2.selfsign"
# SAN
SAN_DNS="*.testsm2.selfsign localhost"
SAN_IPS="127.0.0.1"

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
# sm2-root.cnf (由 mkcert.sh 内嵌模板生成) — L1 根证书
# Subject: C=${C}, ST=${ST}, L=${L}, O=${O_ROOT}

[ req ]
default_bits        = 2048
default_md          = sm3
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
# sm2-intermediate.cnf (由 mkcert.sh 内嵌模板生成) — L2 中间证书
# Subject: C=${C}, ST=${ST}, L=${L}, O=${O_ROOT}, OU=${OU_INTERMEDIATE}, CN=${CN_INTERMEDIATE}

[ req ]
default_bits        = 2048
default_md          = sm3
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
# sm2-${name}-authority.cnf (由 mkcert.sh 内嵌模板生成) — L3 服务证书 CA
# Subject: C=${C}, ST=${ST}, L=${L}, O=${O_ROOT}, OU=${OU_SERVICE}, CN=${CN_SERVICE}

[ req ]
default_bits        = 2048
default_md          = sm3
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

# 实体双证书 cnf (GM/T0024). SAN: sign + enc 共用同一套
# *.testsm2.selfsign, localhost + 1 个 IP; hserver CN 自身由通配覆盖, hclient 在通配范围内.
# 扩展段名 {role}_{type}_req 与 gen_entity_cert 的签发参数保持一致.
write_double_cnf() {
    ent="$1"      # 实体名, 如 hserver
    ctype="$2"    # sign 或 enc
    role="$3"     # server 或 client
    cn="$4"       # CommonName

    cnf_file="${ent}_${ctype}.cnf"
    [ -f "$cnf_file" ] && [ "$RESET_CNF" -ne 1 ] && return 0

    ext_section="${role}_${ctype}_req"
    # sign: 签名用途; enc: 密钥交换/加密用途 (GM/T0024 分工)
    ku="nonRepudiation, digitalSignature"
    [ "$ctype" = "enc" ] && ku="keyAgreement, keyEncipherment, dataEncipherment"
    eku="serverAuth"
    [ "$role" = "client" ] && eku="clientAuth"

    {
        printf '# %s  (由 mkcert.sh 内嵌模板生成, 可手改后重签)\n' "$cnf_file"
        cat <<EOF
[ req ]
default_bits        = 2048
default_md          = sm3
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

[ $ext_section ]
basicConstraints       = critical, CA:FALSE
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
keyUsage               = $ku
subjectAltName         = @alt_names
extendedKeyUsage       = $eku
EOF
    } > "$cnf_file"
    success "生成配置文件: $cnf_file"
}

# 单证书 cnf (RFC8998 GM TLS1.3, 仅服务器侧). RFC8998 §3.3.3 要求 keyUsage 含 digitalSignature, keyEncipherment 兼容密钥传输场景; SAN/subject 与双证书一致.
write_single_cnf() {
    ent="$1"      # 实体名, 如 hserver
    role="$2"     # server
    cn="$3"       # CommonName

    cnf_file="${ent}_single.cnf"
    [ -f "$cnf_file" ] && [ "$RESET_CNF" -ne 1 ] && return 0

    ext_section="${role}_single_req"
    ku="critical, digitalSignature, keyEncipherment"
    eku="serverAuth, clientAuth"

    {
        printf '# %s  (由 mkcert.sh 内嵌模板生成, RFC8998 TLS1.3 单证书, 可手改后重签)\n' "$cnf_file"
        cat <<EOF
[ req ]
default_bits        = 2048
default_md          = sm3
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

[ $ext_section ]
basicConstraints       = critical, CA:FALSE
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
keyUsage               = $ku
subjectAltName         = @alt_names
extendedKeyUsage       = $eku
EOF
    } > "$cnf_file"
    success "生成配置文件: $cnf_file"
}

# 落盘全部 cnf (http 链: 3 个 CA + 4 张实体双证书 + 1 张服务器单证书)
ensure_cnfs() {
    info "检查/生成 cnf 配置模板..."
    write_root_cnf
    write_intermediate_cnf
    write_authority_cnf "http"
    write_double_cnf hserver sign server "$SERVER_CN"
    write_double_cnf hserver enc  server "$SERVER_CN"
    write_double_cnf hclient sign client "$CLIENT_CN"
    write_double_cnf hclient enc  client "$CLIENT_CN"
    write_single_cnf hserver server "$SERVER_CN"
}

# ============================================================
# 环境检查
# ============================================================

check_env() {
    info "检查铜锁环境..."

    if ! command -v "$TONGSUO_BIN" >/dev/null 2>&1; then
        error "未找到 $TONGSUO_BIN 命令，请确认铜锁已安装"
    fi

    version=$("$TONGSUO_BIN" version 2>&1 | head -1)
    success "铜锁版本: $version"

    # 测试 SM2 密钥生成
    info "测试 SM2 算法支持..."
    "$TONGSUO_BIN" genpkey -algorithm ec -pkeyopt ec_paramgen_curve:sm2 -out /tmp/tongsuo_test.key 2>/dev/null \
        || error "SM2 算法不支持，请检查铜锁安装"
    rm -f /tmp/tongsuo_test.key
    success "SM2 算法支持正常"
}

# ============================================================
# 清理旧文件
# ============================================================

cleanup() {
    info "清理旧的证书文件 (保留 .cnf 配置)..."
    rm -f *.key *.csr *.crt *.srl
    success "清理完成"
}

# ============================================================
# 生成 SM2 私钥
# ============================================================

gen_sm2_key() {
    outfile="$1"
    "$TONGSUO_BIN" genpkey -algorithm ec -pkeyopt ec_paramgen_curve:sm2 -out "$outfile"
}

# ============================================================
# SM2 标识强制参数 (sigopt sm2_id 用于签名操作)
# ============================================================

SIGOPT_ARGS="-sigopt sm2_id:${SM2_ID}"
info "SM2 标识强制: ${SM2_ID} (sigopt sm2_id, GM/T 标准值)"

# ============================================================
# 签发 (x509 -req -CAcreateserial, Tongsuo 8.5.0/OpenSSL 3.5+ 行为正确:
# 首次随机 serial 写入 <CA>.srl 并自增, 同 CA 续签 serial 连续)
# ============================================================

ca_sign() {
    # 用法: ca_sign <CA证书> <CA私钥> <CSR> <输出crt> <扩展段名> <有效期天>
    "$TONGSUO_BIN" x509 -req -in "$3" -CA "$1" -CAkey "$2" \
        -CAcreateserial -out "$4" -days "$6" -sm3 \
        -extfile "$7" -extensions "$5" $SIGOPT_ARGS
}

# ============================================================
# 第一层 (L1): 根证书 (root)
# ============================================================

gen_root() {
    info "========== L1: 生成根证书 (root) =========="

    subj="/C=${C}/ST=${ST}/L=${L}/O=${O_ROOT}"

    info "生成根证书私钥..."
    gen_sm2_key root.key

    info "生成自签名根证书 (有效期 ${DAYS_ROOT} 天, 强制 SM2 ID ${SM2_ID})..."
    "$TONGSUO_BIN" req -new -x509 -nodes -key root.key -sm3 -days "$DAYS_ROOT" \
        -out root.crt -config root.cnf -subj "$subj" $SIGOPT_ARGS

    success "根证书生成完成: root.crt"
}

# ============================================================
# 第二层 (L2): 中间证书 (intermediate)
# ============================================================

gen_intermediate() {
    info "========== L2: 生成中间证书 (intermediate) =========="

    subj="/C=${C}/ST=${ST}/L=${L}/O=${O_ROOT}/OU=${OU_INTERMEDIATE}/CN=${CN_INTERMEDIATE}"

    info "生成中间证书私钥..."
    gen_sm2_key intermediate.key

    info "生成中间证书 CSR..."
    "$TONGSUO_BIN" req -config intermediate.cnf -new -key intermediate.key \
        -out intermediate.csr -sm3 -nodes -subj "$subj" $SIGOPT_ARGS

    info "使用根证书签发中间证书 (有效期 ${DAYS_INTERMEDIATE} 天)..."
    ca_sign root.crt root.key intermediate.csr intermediate.crt \
        v3_intermediate_ca "$DAYS_INTERMEDIATE" intermediate.cnf \
        || error "中间证书签发失败"

    success "中间证书生成完成: intermediate.crt"
}

# ============================================================
# 第三层 (L3): 服务证书 CA (http-authority = Service CA)
# ============================================================

gen_service_ca() {
    info "========== L3: 生成服务证书 CA (http-authority) =========="

    subj="/C=${C}/ST=${ST}/L=${L}/O=${O_ROOT}/OU=${OU_SERVICE}/CN=${CN_SERVICE}"

    info "生成 http-authority 私钥..."
    gen_sm2_key http-authority.key

    info "生成 http-authority CSR..."
    "$TONGSUO_BIN" req -config http-authority.cnf -new -key http-authority.key \
        -out http-authority.csr -sm3 -nodes -subj "$subj" $SIGOPT_ARGS

    info "使用中间证书签发 Service CA (有效期 ${DAYS_AUTHORITY} 天)..."
    ca_sign intermediate.crt intermediate.key http-authority.csr http-authority.crt \
        v3_service_ca "$DAYS_AUTHORITY" http-authority.cnf \
        || error "Service CA 签发失败"

    success "Service CA 生成完成: http-authority.crt"
}

# ============================================================
# 第四层 (L4): 实体双证书 (GM/T0024: sign + enc 分离)
# ============================================================

gen_entity_cert() {
    entity_prefix="$1"    # 实体证书前缀, 如 hserver
    cert_type="$2"        # sign 或 enc
    role="$3"             # server 或 client
    cn="$4"               # CommonName

    cnf_file="${entity_prefix}_${cert_type}.cnf"
    key_file="${entity_prefix}_${cert_type}.key"
    csr_file="${entity_prefix}_${cert_type}.csr"
    crt_file="${entity_prefix}_${cert_type}.crt"
    ext_section="${role}_${cert_type}_req"

    subj="/C=${C}/ST=${ST}/L=${L}/O=${O_ROOT}/CN=${cn}"

    info "生成 ${entity_prefix}_${cert_type} 私钥..."
    gen_sm2_key "$key_file"

    info "生成 ${entity_prefix}_${cert_type} CSR..."
    "$TONGSUO_BIN" req -config "$cnf_file" -new -key "$key_file" \
        -out "$csr_file" -sm3 -nodes -subj "$subj" $SIGOPT_ARGS

    info "使用 http-authority 签发 ${entity_prefix}_${cert_type} (有效期 ${DAYS_ENTITY} 天)..."
    ca_sign http-authority.crt http-authority.key "$csr_file" "$crt_file" \
        "$ext_section" "$DAYS_ENTITY" "$cnf_file" \
        || error "${entity_prefix}_${cert_type} 签发失败"

    success "${entity_prefix}_${cert_type} 证书生成完成: ${crt_file}"
}

gen_http_certs() {
    info "========== L4: 生成 HTTP 实体双证书 =========="

    # 服务器签名证书
    gen_entity_cert "hserver" "sign" "server" "$SERVER_CN"
    # 服务器加密证书
    gen_entity_cert "hserver" "enc"  "server" "$SERVER_CN"
    # 服务器单证书 (RFC8998 GM TLS1.3, 扩展段 server_single_req)
    gen_entity_cert "hserver" "single" "server" "$SERVER_CN"
    # 客户端签名证书
    gen_entity_cert "hclient" "sign" "client" "$CLIENT_CN"
    # 客户端加密证书
    gen_entity_cert "hclient" "enc"  "client" "$CLIENT_CN"

    success "HTTP 实体双证书全部生成完成"
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

    for ec in hserver_sign hserver_enc hclient_sign hclient_enc hserver_single; do
        cat "${ec}.crt" http-authority.crt intermediate.crt > "${ec}-chain.crt"
        success "生成: ${ec}-chain.crt"
    done
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

    if "$TONGSUO_BIN" verify -CAfile "$cafile" "$cert" >/dev/null 2>&1; then
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
    if "$TONGSUO_BIN" verify -CAfile root.crt root.crt >/dev/null 2>&1; then
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

    # 验证实体双证书
    verify_one http-full-chain.crt hserver_sign.crt "hserver_sign"
    verify_one http-full-chain.crt hserver_enc.crt  "hserver_enc"
    verify_one http-full-chain.crt hserver_single.crt "hserver_single (RFC8998)"
    verify_one http-full-chain.crt hclient_sign.crt "hclient_sign"
    verify_one http-full-chain.crt hclient_enc.crt  "hclient_enc"

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

    enddate=$("$TONGSUO_BIN" x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$enddate" ] || return

    end_norm=$(parse_openssl_date "$enddate") || return
    # openssl enddate 固定为 UTC 显示, 用 date -u 解析避免宿主 TZ 偏移
    end_epoch=$(date -u -d "$end_norm" +%s 2>/dev/null)
    now_epoch=$(date +%s)

    [ -n "$end_epoch" ] || return
    days_left=$(( (end_epoch - now_epoch) / 86400 ))
    if [ "$days_left" -lt 90 ]; then
        warn "${desc}: ${days_left} 天后过期 (${enddate})"
    else
        success "${desc}: ${days_left} 天后过期 (${enddate})"
    fi
}

show_expiry_info() {
    info "========== 证书有效期信息 =========="

    for cd_n in root intermediate http-authority hserver_sign hserver_enc hserver_single hclient_sign hclient_enc; do
        show_cert_days "${cd_n}.crt" "$cd_n"
    done
}

# ============================================================
# 统计输出
# ============================================================

show_summary() {
    echo ""
    echo "============================================================"
    echo "  铜锁国密 SM2 双证书生成完成"
    echo "============================================================"
    echo ""
    echo "  证书层级结构:"
    echo "    L1 root (根CA)"
    echo "    └── L2 intermediate (中间CA)"
    echo "        └── L3 http-authority (Service CA)"
    echo "            ├── L4 hserver_sign.crt (NTLS 国密签名)"
    echo "            ├── L4 hserver_enc.crt (NTLS 国密加密)"
    echo "            ├── L4 hserver_single.crt (RFC8998 GM TLS1.3 单证书)"
    echo "            ├── L4 hclient_sign.crt (NTLS 国密客户端签名)"
    echo "            └── L4 hclient_enc.crt (NTLS 国密客户端加密)"
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
    echo "  算法: SM2 (密钥) + SM3 (摘要)"
    echo "  模式: 双证书 (签名证书 + 加密证书) + 单证书 (RFC8998)"
    echo "  协议: NTLS (ssl_ntls on) / GM TLS1.3 (RFC8998)"
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
            -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
            *) warn "未知参数: $arg (忽略)";;
        esac
    done

    echo ""
    echo "============================================================"
    echo "  铜锁国密 SM2 双证书生成脚本"
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

    # 7. L4: 实体双证书 (http)
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
