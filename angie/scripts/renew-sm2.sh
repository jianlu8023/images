#!/bin/sh
# ============================================================
# 铜锁国密 SM2 双证书重新签发工具 (POSIX sh, http 链 ×1)
# mkcert.sh 的配套续签工具: 注册表/扩展段与 mkcert.sh 保持一致
#
# 证书层级:
#   root -> intermediate -> http-authority
#          -> 实体双证书 (xxx_sign 签名证书 + xxx_enc 加密证书)
#
# 功能:
#   check      检查证书有效期 / 证书链验证 / 私钥匹配 / 链文件新鲜度 / 双证书同步
#   renew      重新签发指定证书 (保留原私钥), 双证书可按对续签
#   auto       自动续签 N 天内到期的证书 (按层级自上而下, 双证书成对续签)
#   renew-all  强制重新签发所有证书
#   verify     验证证书链与私钥匹配
#   list       列出证书清单
#   chains     重建所有链文件
#
# 国密双证书说明:
#   - 每个实体有 sign (签名) 与 enc (加密) 两张证书, 私钥相互独立
#   - ./renew.sh renew hserver       -> 成对续签 hserver_sign + hserver_enc
#   - ./renew.sh renew hserver_sign  -> 只续签签名证书, enc 不动
#   - auto 模式下任一张到期即成对续签, 保证双证书有效期同步
#   - 续签使用 SM2 密钥 + SM3 摘要 (-sm3), DN 优先取自旧证书, 缺失时用注册表默认值
#   - 所有 SM2 签名操作显式强制 sm2_id=1234567812345678 (GM/T 标准值, 与 mkcert.sh 一致),
#     保证续签后的链可被 Go gmsm / 原生 OpenSSL 按标准 ID 校验
#
# 用法示例:
#   ./renew.sh check                    # 检查全部证书
#   ./renew.sh check hserver            # 只检查 hserver 双证书
#   ./renew.sh renew hserver            # 成对续签 hserver 双证书 (365 天)
#   ./renew.sh renew hserver_sign -d 730 # 只续签签名证书, 730 天
#   ./renew.sh auto -d 60 -y            # 60 天阈值自动续签, 免确认 (cron 用)
# ============================================================

# ============================================================
# 配置
# ============================================================

# 铜锁命令路径, 可用环境变量覆盖: TONGSUO_BIN=/path/to/tongsuo ./renew.sh ...
TONGSUO_BIN="${TONGSUO_BIN:-/usr/local/tongsuo/bin/tongsuo}"

# SM2 签名者标识: GM/T 标准默认值, 所有签名操作显式强制
SM2_ID="${SM2_ID:-1234567812345678}"
# SM2_SIGOPT: auto(默认, tongsuo 强制) | 1(强制) | 0(关闭)
SM2_SIGOPT="${SM2_SIGOPT:-auto}"

# 自动续签的过期阈值 (天)
THRESHOLD_DAYS=30

# 备份目录
BACKUP_DIR="backup"

# CA 签发 serial 文件由 x509 -req -CAcreateserial 自动管理 (<CA>.srl), 无 db 目录

# 切换到脚本所在目录, 保证相对路径可用
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
cd "$SCRIPT_DIR" || { printf 'ERROR: 无法进入脚本目录 %s\n' "$SCRIPT_DIR"; exit 1; }

# ============================================================
# 颜色输出 (非终端时自动关闭)
# ============================================================

if [ -t 1 ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'
    C_OFF='\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_OFF=''
fi

info()    { printf "${C_BLUE}[INFO]${C_OFF} %s\n" "$*"; }
success() { printf "${C_GREEN}[OK]${C_OFF}   %s\n" "$*"; }
warn()    { printf "${C_YELLOW}[WARN]${C_OFF} %s\n" "$*"; }
err()     { printf "${C_RED}[ERROR]${C_OFF} %s\n" "$*"; }
die()     { err "$*"; exit 1; }

# ============================================================
# SM2 标识强制参数 (使用处需不加引号展开以词分割)
# ============================================================

sm2_id_enabled() {
    case "$SM2_SIGOPT" in
        0) return 1 ;;
        1) return 0 ;;
        *) case "$TONGSUO_BIN" in
               *openssl*) return 1 ;;
               *) return 0 ;;
           esac ;;
    esac
}

SIGOPT_ARGS=""
if sm2_id_enabled; then
    case "$TONGSUO_BIN" in
        *openssl*)
            # 原生 openssl 参数名是 distid; 其 x509 -req 带 sigopt 有 CSR 自签校验缺陷, 默认不强制
            SIGOPT_ARGS="-sigopt distid:${SM2_ID}"
            warn "原生 openssl: x509 -req 带 sigopt 有已知缺陷, 建议 SM2_SIGOPT=0"
            ;;
        *)
            SIGOPT_ARGS="-sigopt sm2_id:${SM2_ID}"
            info "SM2 标识强制: ${SM2_ID} (sigopt sm2_id, GM/T 标准值)"
            ;;
    esac
else
    info "SM2 标识: 使用工具默认值 (tongsuo 默认即 ${SM2_ID})"
fi

# ============================================================
# 签发 (x509 -req -CAcreateserial, 与 mkcert.sh 一致)
# Tongsuo 8.5.0 (OpenSSL 3.5.4) 行为正确: 首次随机 serial 写入
# <CA>.srl 并自增, 续签 serial 连续; 不再需要 ca 命令的 db 目录.
# 注意: Tongsuo 8.4.0 / OpenSSL 3.0.x 会无条件预填随机 serial、
# -CAcreateserial 被静默忽略, 不支持在旧版上续签.
# ============================================================

ca_sign() {
    # 用法: ca_sign <CA证书> <CA私钥> <CSR> <输出crt> <扩展段名> <有效期天>
    "$TONGSUO_BIN" x509 -req -in "$3" -CA "$1" -CAkey "$2" \
        -CAcreateserial -out "$4" -days "$6" -sm3 \
        -extfile "$7" -extensions "$5" $SIGOPT_ARGS
}

# ============================================================
# 证书注册表 (http 链 ×1, 与 mkcert.sh 的扩展段保持一致)
# 格式: 名称|签发者证书|签发者私钥|配置文件|扩展段|有效期(天)|类型|描述|默认DN
# 签发者为 self 表示自签名 (仅 root)
# 注意: 行的顺序即层级顺序 (root -> intermediate -> authority -> 实体双证书),
#       auto / renew-all 按此顺序自上而下续签; 同一实体的 sign 与 enc 相邻
# ============================================================

reg() {
    cat <<'EOF'
root|self|root.key|root.cnf|v3_ca|3650|root|根证书|/C=CN/ST=Xinjiang/L=Urumqi/O=Test SM2
intermediate|root.crt|root.key|intermediate.cnf|v3_intermediate_ca|1825|intermediate|中间CA|/C=CN/ST=Xinjiang/L=Urumqi/O=Test SM2/OU=Intermediate Certificate Authority/CN=Test SM2 Intermediate CA
http-authority|intermediate.crt|intermediate.key|http-authority.cnf|v3_service_ca|1095|authority|HTTP服务CA|/C=CN/ST=Xinjiang/L=Urumqi/O=Test SM2/OU=Service Certificate Authority/CN=Test SM2 Service CA
hserver_sign|http-authority.crt|http-authority.key|hserver_sign.cnf|server_sign_req|365|entity|HTTP服务器签名证书|/C=CN/ST=Xinjiang/L=Urumqi/O=Test SM2/CN=www.testsm2.selfsign
hserver_enc|http-authority.crt|http-authority.key|hserver_enc.cnf|server_enc_req|365|entity|HTTP服务器加密证书|/C=CN/ST=Xinjiang/L=Urumqi/O=Test SM2/CN=www.testsm2.selfsign
hserver_single|http-authority.crt|http-authority.key|hserver_single.cnf|server_single_req|365|entity|HTTP服务器单证书(RFC8998 GM TLS1.3)|/C=CN/ST=Xinjiang/L=Urumqi/O=Test SM2/CN=www.testsm2.selfsign
hclient_sign|http-authority.crt|http-authority.key|hclient_sign.cnf|client_sign_req|365|entity|HTTP客户端签名证书|/C=CN/ST=Xinjiang/L=Urumqi/O=Test SM2/CN=hclient.testsm2.selfsign
hclient_enc|http-authority.crt|http-authority.key|hclient_enc.cnf|client_enc_req|365|entity|HTTP客户端加密证书|/C=CN/ST=Xinjiang/L=Urumqi/O=Test SM2/CN=hclient.testsm2.selfsign
EOF
}

# 按名称查找注册表行, 未找到输出空
reg_lookup() {
    reg | awk -F'|' -v n="$1" '$1==n{print; exit}'
}

# 列出某类型的所有证书名
reg_names_by_type() {
    reg | awk -F'|' -v t="$1" '$7==t{print $1}'
}

# 规范化证书名: 允许 hserver_sign 或 hserver_sign.crt
norm_name() {
    printf '%s' "$1" | sed 's/\.crt$//'
}

# 实体双证书的另一张 (hserver_sign <-> hserver_enc), 非实体输出空
pair_of() {
    case "$1" in
        *_sign) printf '%s_enc' "${1%_sign}" ;;
        *_enc)  printf '%s_sign' "${1%_enc}" ;;
        *)      printf '' ;;
    esac
}

# 展开用户输入为具体证书名列表 (每行一个):
#   hserver       -> hserver_sign + hserver_enc
#   hserver_sign  -> hserver_sign
#   root          -> root
# 未知名原样输出, 由下游报错
expand_names() {
    for xn_arg in "$@"; do
        xn=$(norm_name "$xn_arg")
        if [ -n "$(reg_lookup "$xn")" ]; then
            printf '%s\n' "$xn"
        elif [ -n "$(reg_lookup "${xn}_sign")" ]; then
            printf '%s\n' "${xn}_sign" "${xn}_enc"
        else
            printf '%s\n' "$xn"
        fi
    done
}

# ============================================================
# 工具函数
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

# 取证书到期时间字符串, 失败输出空
get_enddate() {
    "$TONGSUO_BIN" x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2-
}

# 取证书到期时间对应的 UTC epoch 秒, 失败输出空
enddate_epoch() {
    eed_end=$(get_enddate "$1")
    [ -n "$eed_end" ] || return 1
    eed_norm=$(parse_openssl_date "$eed_end") || return 1
    # openssl enddate 固定为 UTC 显示, 用 date -u 解析避免宿主 TZ 偏移
    date -u -d "$eed_norm" +%s 2>/dev/null
}

# 取证书剩余天数, 失败输出 "?"
days_left() {
    ep=$(enddate_epoch "$1")
    [ -n "$ep" ] || { printf '?'; return; }
    now=$(date +%s)
    printf '%s' $(( (ep - now) / 86400 ))
}

# 证书是否在 N 天后仍然有效 (rc=0 有效; rc!=0 将在 N 天内到期/已过期/无法解析)
valid_within() {
    "$TONGSUO_BIN" x509 -in "$1" -noout -checkend $(( $2 * 86400 )) >/dev/null 2>&1
}

# 证书与私钥是否匹配 (rc=0 匹配)
key_matches() {
    kc="${1%.crt}.key"
    [ -f "$kc" ] || return 2
    h1=$("$TONGSUO_BIN" x509 -in "$1" -noout -pubkey 2>/dev/null | "$TONGSUO_BIN" md5 2>/dev/null)
    h2=$("$TONGSUO_BIN" pkey -in "$kc" -pubout 2>/dev/null | "$TONGSUO_BIN" md5 2>/dev/null)
    [ -n "$h1" ] && [ "$h1" = "$h2" ]
}

# 从旧证书提取 DN, 转成 -subj 用的 /C=xx/... 格式, 失败输出空
# (续签必须显式传 -subj; 新 cnf 为 prompt=no 显式 DN, 但 -subj 优先级更高)
# 兼容两种输出:
#   -nameopt compat -> subject=/C=CN/ST=... (斜杠格式, 直接可用)
#   默认输出        -> subject=C = CN, ST = ... (逗号格式, 需转换)
get_subj_from_cert() {
    gs_raw=$("$TONGSUO_BIN" x509 -in "$1" -noout -subject -nameopt compat 2>/dev/null)
    [ -n "$gs_raw" ] || gs_raw=$("$TONGSUO_BIN" x509 -in "$1" -noout -subject 2>/dev/null)
    [ -n "$gs_raw" ] || { printf ''; return; }
    gs_subj=$(printf '%s' "$gs_raw" | sed -e 's/^subject=[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$gs_subj" in
        /*)
            # 斜杠格式: /C=CN/ST=... 直接可用
            printf '%s' "$gs_subj"
            ;;
        *)
            # 逗号格式: C = CN, ST = ... -> /C=CN/ST=...
            gs_subj=$(printf '%s' "$gs_subj" \
                | sed -e 's/[[:space:]]*=[[:space:]]*/=/g' \
                      -e 's/,[[:space:]]*/\//g')
            case "$gs_subj" in
                *[![:space:]]*) printf '/%s' "$gs_subj" ;;
                *) printf '' ;;
            esac
            ;;
    esac
}

# 为指定证书返回验证用的 CAfile (复用持久化链文件, 不使用临时文件)
# 链文件缺失时现场生成
make_cafile() {
    mcf_name="$1"
    mcf_type="$2"
    mcf_issuer="$3"
    case "$mcf_type" in
        root|intermediate)
            printf '%s' "root.crt"
            ;;
        authority)
            if [ ! -f root-intermediate-chain.crt ]; then
                cat root.crt intermediate.crt > root-intermediate-chain.crt
            fi
            printf '%s' "root-intermediate-chain.crt"
            ;;
        entity)
            # issuer 形如 http-authority.crt -> http-full-chain.crt
            mcf_auth="${mcf_issuer%-authority.crt}"
            if [ ! -f "${mcf_auth}-full-chain.crt" ]; then
                cat root.crt intermediate.crt "$mcf_issuer" > "${mcf_auth}-full-chain.crt"
            fi
            printf '%s' "${mcf_auth}-full-chain.crt"
            ;;
        *)
            printf '%s' ""
            ;;
    esac
}

# 验证单个证书的链 (rc=0 通过)
verify_chain() {
    vc_name="$1"
    vc_line=$(reg_lookup "$vc_name")
    [ -n "$vc_line" ] || return 2
    IFS='|' read -r _n _i _k _c _e _d vc_type _s <<EOF
$vc_line
EOF
    vc_ca=$(make_cafile "$vc_name" "$vc_type" "$_i")
    [ -n "$vc_ca" ] || return 2
    "$TONGSUO_BIN" verify -CAfile "$vc_ca" "${vc_name}.crt" >/dev/null 2>&1
}

# ============================================================
# 链文件构建
# ============================================================

# 重建所有链文件:
#   root-intermediate-chain.crt   = root + intermediate
#   <auth>-full-chain.crt         = root + intermediate + <auth>-authority
#   <leaf>-chain.crt              = leaf + <auth>-authority + intermediate (部署用)
# 实体双证书每张各有一个部署链: hserver_sign-chain.crt / hserver_enc-chain.crt
build_chains() {
    bc_fail=0

    if [ -f root.crt ] && [ -f intermediate.crt ]; then
        cat root.crt intermediate.crt > root-intermediate-chain.crt || bc_fail=$((bc_fail+1))
    fi

    for bc_auth in $(reg_names_by_type authority); do
        if [ -f "${bc_auth}.crt" ] && [ -f root.crt ] && [ -f intermediate.crt ]; then
            cat root.crt intermediate.crt "${bc_auth}.crt" > "${bc_auth%-authority}-full-chain.crt" \
                || bc_fail=$((bc_fail+1))
        fi
    done

    reg | awk -F'|' '$7=="entity"{print $1"|"$2}' | while IFS='|' read -r bc_leaf bc_issuer; do
        if [ -f "${bc_leaf}.crt" ] && [ -f "$bc_issuer" ] && [ -f intermediate.crt ]; then
            if cat "${bc_leaf}.crt" "$bc_issuer" intermediate.crt > "${bc_leaf}-chain.crt"; then
                printf "${C_GREEN}[OK]${C_OFF}   重建链文件: %s-chain.crt\n" "$bc_leaf"
            else
                printf "${C_RED}[ERROR]${C_OFF} 重建链文件失败: %s-chain.crt\n" "$bc_leaf"
            fi
        fi
    done

    if [ "$bc_fail" -gt 0 ]; then
        warn "有 ${bc_fail} 个 CA 链文件重建失败"
        return 1
    fi
    return 0
}

# ============================================================
# 检查 (check)
# ============================================================

# 检查单个证书, 打印一行结果
# rc: 0 正常; 1 需要续签/有异常
check_one() {
    co_name="$1"
    co_line=$(reg_lookup "$co_name")
    if [ -z "$co_line" ]; then
        warn "未知证书: ${co_name} (用 list 查看支持的证书)"
        CHECK_FAILED=$((CHECK_FAILED+1))
        return 1
    fi

    IFS='|' read -r _n _i _k _c _e _d co_type co_desc _s <<EOF
$co_line
EOF

    if [ ! -f "${co_name}.crt" ]; then
        printf "${C_RED}[丢失]${C_OFF}  %-20s %-10s 证书文件不存在\n" "$co_name" "$co_type"
        CHECK_EXPIRED=$((CHECK_EXPIRED+1))
        return 1
    fi

    co_days=$(days_left "${co_name}.crt")
    co_end=$(get_enddate "${co_name}.crt")

    # 链验证
    if verify_chain "$co_name"; then
        co_v="链:OK"
    else
        co_v="链:FAIL"
    fi

    # 私钥匹配
    if key_matches "${co_name}.crt"; then
        co_k="钥:OK"
    else
        co_k="钥:FAIL"
    fi

    # 实体证书的部署链文件新鲜度 (serial 是否一致)
    co_chain="-"
    if [ "$co_type" = "entity" ] && [ -f "${co_name}-chain.crt" ]; then
        co_s1=$("$TONGSUO_BIN" x509 -in "${co_name}.crt" -noout -serial 2>/dev/null | cut -d= -f2)
        co_s2=$("$TONGSUO_BIN" x509 -in "${co_name}-chain.crt" -noout -serial 2>/dev/null | cut -d= -f2)
        if [ -n "$co_s1" ] && [ "$co_s1" = "$co_s2" ]; then
            co_chain="链文件:OK"
        else
            co_chain="链文件:过期"
        fi
    elif [ "$co_type" = "entity" ]; then
        co_chain="链文件:缺失"
    fi

    co_status=''
    co_rc=0
    case "$co_days" in
        '?')
            co_status="无法解析"
            co_rc=1
            ;;
        *)
            if [ "$co_days" -le 0 ]; then
                co_status="已过期"
                co_rc=1
            elif [ "$co_days" -lt "$THRESHOLD_DAYS" ]; then
                co_status="即将过期"
                co_rc=1
            else
                co_status="正常"
            fi
            ;;
    esac

    if [ "$co_rc" -ne 0 ]; then
        printf "${C_YELLOW}[续签]${C_OFF}  %-20s %-10s 剩余 %-5s 天 %-26s %s %s %s\n" \
            "$co_name" "$co_type" "$co_days" "$co_end" "$co_v" "$co_k" "$co_chain"
    else
        printf "${C_GREEN}[正常]${C_OFF}  %-20s %-10s 剩余 %-5s 天 %-26s %s %s %s\n" \
            "$co_name" "$co_type" "$co_days" "$co_end" "$co_v" "$co_k" "$co_chain"
    fi

    if [ "$co_v" != "链:OK" ] || [ "$co_k" != "钥:OK" ] || [ "$co_chain" = "链文件:过期" ]; then
        co_rc=1
    fi

    if [ "$co_rc" -ne 0 ]; then
        CHECK_EXPIRED=$((CHECK_EXPIRED+1))
    else
        CHECK_OK=$((CHECK_OK+1))
    fi
    return $co_rc
}

# 双证书同步检查: 同一实体的 sign/enc 剩余天数差超过阈值则告警
check_pair_sync() {
    cps_bases=$(reg_names_by_type entity | sed -e 's/_sign$//' -e 's/_enc$//' | awk '!seen[$0]++')
    for cps_b in $cps_bases; do
        [ -f "${cps_b}_sign.crt" ] && [ -f "${cps_b}_enc.crt" ] || continue
        cps_ds=$(days_left "${cps_b}_sign.crt")
        cps_de=$(days_left "${cps_b}_enc.crt")
        [ "$cps_ds" = "?" ] && continue
        [ "$cps_de" = "?" ] && continue
        cps_diff=$(( cps_ds - cps_de ))
        [ "$cps_diff" -lt 0 ] && cps_diff=$(( 0 - cps_diff ))
        if [ "$cps_diff" -gt "$PAIR_SYNC_TOLERANCE" ]; then
            warn "双证书有效期不同步: ${cps_b}_sign 剩 ${cps_ds} 天, ${cps_b}_enc 剩 ${cps_de} 天 (建议成对续签: ./renew.sh renew ${cps_b})"
            CHECK_PAIR_WARN=$((CHECK_PAIR_WARN+1))
        fi
    done
}

# ============================================================
# 重新签发 (renew)
# ============================================================

# 重新签发单个证书 (保留原私钥)
# 用法: renew_one <名称> [有效期天数]
renew_one() {
    ro_name="$1"
    ro_days="${2:-}"
    ro_line=$(reg_lookup "$ro_name")

    if [ -z "$ro_line" ]; then
        err "未知证书: ${ro_name} (用 ./renew.sh list 查看支持的证书)"
        return 1
    fi

    IFS='|' read -r ro_name ro_issuer ro_issuer_key ro_cnf ro_ext ro_def_days ro_type ro_desc ro_subj <<EOF
$ro_line
EOF

    [ -n "$ro_days" ] || ro_days="$ro_def_days"

    ro_key="${ro_name}.key"
    ro_csr="${ro_name}.csr"
    ro_crt="${ro_name}.crt"

    # 必要文件检查
    if [ ! -f "$ro_cnf" ]; then
        err "${ro_desc} (${ro_name}): 配置文件 ${ro_cnf} 不存在"
        return 1
    fi
    if [ ! -f "$ro_key" ]; then
        err "${ro_desc} (${ro_name}): 私钥 ${ro_key} 不存在 (续签保留私钥, 缺私钥请用 mkcert.sh 重新生成)"
        return 1
    fi

    # 上级 CA 检查
    if [ "$ro_issuer" != "self" ]; then
        if [ ! -f "$ro_issuer" ] || [ ! -f "$ro_issuer_key" ]; then
            err "${ro_desc} (${ro_name}): 签发者 ${ro_issuer} 或其私钥不存在, 请先续签/生成上级CA"
            return 1
        fi
        ro_issuer_days=$(days_left "$ro_issuer")
        if [ "$ro_issuer_days" != "?" ] && [ "$ro_issuer_days" -lt "$ro_days" ] 2>/dev/null; then
            warn "上级CA ${ro_issuer} 仅剩 ${ro_issuer_days} 天, 早于新证书的 ${ro_days} 天有效期, 建议同时续签上级CA"
        fi
    fi

    # 确定 DN: 优先取旧证书的 DN (保留手工调整过的内容), 旧证书缺失时用注册表默认值
    ro_subj_use=""
    if [ -f "$ro_crt" ]; then
        ro_subj_use=$(get_subj_from_cert "$ro_crt")
    fi
    [ -n "$ro_subj_use" ] || ro_subj_use="$ro_subj"
    if [ -z "$ro_subj_use" ]; then
        err "${ro_desc} (${ro_name}): 无法确定 DN (旧证书不可解析且注册表无默认值)"
        return 1
    fi

    info "重新签发: ${ro_desc} (${ro_name}), 有效期 ${ro_days} 天, SM2/SM3"

    # 备份旧证书
    if [ -f "$ro_crt" ]; then
        mkdir -p "$BACKUP_DIR" || return 1
        ro_stamp=$(date +%Y%m%d-%H%M%S)
        cp "$ro_crt" "${BACKUP_DIR}/${ro_name}.crt.${ro_stamp}" || return 1
        info "  已备份: ${BACKUP_DIR}/${ro_name}.crt.${ro_stamp}"
    fi

    # 重新生成 CSR (使用原私钥, 必须显式传 -subj)
    info "  生成新 CSR (${ro_csr})..."
    "$TONGSUO_BIN" req -config "$ro_cnf" -new -key "$ro_key" -sm3 \
        -out "$ro_csr" -subj "$ro_subj_use" $SIGOPT_ARGS \
        || { err "  生成 CSR 失败"; return 1; }

    # 签发
    if [ "$ro_issuer" = "self" ]; then
        info "  自签名签发中..."
        "$TONGSUO_BIN" req -new -x509 -key "$ro_key" -sm3 -days "$ro_days" \
            -out "$ro_crt" -config "$ro_cnf" -subj "$ro_subj_use" $SIGOPT_ARGS \
            || { err "  自签名失败"; return 1; }
    else
        info "  由 ${ro_issuer} 签发中..."
        ca_sign "$ro_issuer" "$ro_issuer_key" "$ro_csr" "$ro_crt" \
            "$ro_ext" "$ro_days" "$ro_cnf" \
            || { err "  签发失败"; return 1; }
    fi

    # 验证新证书
    if ! verify_chain "$ro_name"; then
        err "  新证书链验证失败"
        return 1
    fi
    if ! key_matches "$ro_crt"; then
        err "  新证书与私钥不匹配"
        return 1
    fi

    ro_new_days=$(days_left "$ro_crt")
    success "  ${ro_desc} 续签成功, 新到期时间: $(get_enddate "$ro_crt") (剩余 ${ro_new_days} 天)"

    # 双证书另一半的同步提示
    ro_pair=$(pair_of "$ro_name")
    if [ -n "$ro_pair" ] && [ -f "${ro_pair}.crt" ]; then
        ro_pair_days=$(days_left "${ro_pair}.crt")
        if [ "$ro_pair_days" != "?" ] && [ $(( ro_new_days - ro_pair_days )) -gt "$PAIR_SYNC_TOLERANCE" ] 2>/dev/null; then
            warn "  双证书不同步: ${ro_pair} 仅剩 ${ro_pair_days} 天, 建议成对续签: ./renew.sh renew ${ro_name%_sign}"
        fi
    fi
    return 0
}

# ============================================================
# 子命令实现
# ============================================================

# 双证书同步容差 (天): sign/enc 剩余天数差超过该值告警
PAIR_SYNC_TOLERANCE=30

cmd_check() {
    cc_targets="$*"
    info "国密双证书检查 (续签阈值: ${THRESHOLD_DAYS} 天, 同步容差: ${PAIR_SYNC_TOLERANCE} 天)  目录: $SCRIPT_DIR"
    printf '%s\n' "-----------------------------------------------------------------------------------------------"
    CHECK_OK=0
    CHECK_EXPIRED=0
    CHECK_FAILED=0
    CHECK_PAIR_WARN=0

    if [ -z "$cc_targets" ]; then
        # 全部证书, 按层级顺序
        cc_all=$(reg | awk -F'|' '{print $1}')
        for cc_n in $cc_all; do
            check_one "$cc_n"
        done
    else
        for cc_n in $(expand_names $cc_targets); do
            check_one "$cc_n"
        done
    fi

    # 双证书同步检查
    check_pair_sync

    printf '%s\n' "-----------------------------------------------------------------------------------------------"
    if [ "$CHECK_PAIR_WARN" -gt 0 ]; then
        warn "双证书不同步: ${CHECK_PAIR_WARN} 对"
    fi
    if [ "$CHECK_EXPIRED" -gt 0 ] || [ "$CHECK_PAIR_WARN" -gt 0 ]; then
        warn "需要处理: ${CHECK_EXPIRED} 张, 正常: ${CHECK_OK} 张  ->  运行 ./renew.sh auto 或 ./renew.sh renew <名称>"
        return 1
    fi
    success "全部正常: ${CHECK_OK} 张证书"
    return 0
}

cmd_verify() {
    cv_targets="$*"
    cv_fail=0
    cv_total=0

    if [ -z "$cv_targets" ]; then
        cv_all=$(reg | awk -F'|' '{print $1}')
    else
        cv_all=$(expand_names $cv_targets)
    fi

    info "证书链与私钥验证"
    for cv_n in $cv_all; do
        cv_line=$(reg_lookup "$cv_n")
        [ -n "$cv_line" ] || { err "未知证书: $cv_n"; cv_fail=$((cv_fail+1)); continue; }
        if [ ! -f "${cv_n}.crt" ]; then
            warn "${cv_n}: 证书文件不存在"
            cv_fail=$((cv_fail+1))
            continue
        fi
        cv_total=$((cv_total+1))
        cv_line_ok=OK
        verify_chain "$cv_n" || cv_line_ok=FAIL
        cv_key_ok=OK
        key_matches "${cv_n}.crt" || cv_key_ok=FAIL
        if [ "$cv_line_ok" = "OK" ] && [ "$cv_key_ok" = "OK" ]; then
            printf "${C_GREEN}[OK]${C_OFF}   %-20s 链验证通过, 私钥匹配\n" "$cv_n"
        else
            printf "${C_RED}[FAIL]${C_OFF} %-20s 链:%s 私钥:%s\n" "$cv_n" "$cv_line_ok" "$cv_key_ok"
            cv_fail=$((cv_fail+1))
        fi
    done

    if [ "$cv_fail" -gt 0 ]; then
        err "验证失败 ${cv_fail}/${cv_total}"
        return 1
    fi
    success "全部 ${cv_total} 张证书验证通过"
    return 0
}

cmd_list() {
    printf '%s\n' "国密双证书清单 (层级顺序, 同一实体的 sign/enc 相邻):"
    reg | awk -F'|' '{printf "  %-22s %-12s %-26s %s天\n", $1, $7, $2, $6}'
}

cmd_chains() {
    info "重建所有链文件..."
    build_chains
    [ -f root-intermediate-chain.crt ] && success "root-intermediate-chain.crt"
    for c_a in $(reg_names_by_type authority); do
        [ -f "${c_a%-authority}-full-chain.crt" ] && success "${c_a%-authority}-full-chain.crt"
    done
    return 0
}

cmd_renew() {
    cr_targets=""
    cr_days=""
    # 解析参数: 证书名 + 可选 -d 天数
    for cr_arg in "$@"; do
        case "$cr_arg" in
            -d|--days)
                ;;
            [0-9]*)
                if [ "$cr_prev" = "-d" ] || [ "$cr_prev" = "--days" ]; then
                    cr_days="$cr_arg"
                else
                    cr_targets="$cr_targets $cr_arg"
                fi
                ;;
            -*)
                ;;
            *)
                cr_targets="$cr_targets $cr_arg"
                ;;
        esac
        cr_prev="$cr_arg"
    done

    [ -n "$cr_targets" ] || die "用法: ./renew.sh renew <证书名> [-d 天数]   (例: ./renew.sh renew hserver 或 ./renew.sh renew hserver_sign)"

    # 展开双证书 (hserver -> hserver_sign + hserver_enc)
    cr_list=$(expand_names $cr_targets)

    cr_ok=0
    cr_fail=0
    for cr_n in $cr_list; do
        if renew_one "$cr_n" "$cr_days"; then
            cr_ok=$((cr_ok+1))
        else
            cr_fail=$((cr_fail+1))
        fi
    done

    # 重建链文件
    info "重建链文件..."
    build_chains

    # 复验
    info "复验新证书..."
    cr_vfail=0
    for cr_n in $cr_list; do
        if [ -f "${cr_n}.crt" ]; then
            verify_chain "$cr_n" || { err "${cr_n}: 链验证失败"; cr_vfail=$((cr_vfail+1)); }
        fi
    done

    printf '%s\n' ""
    if [ "$cr_fail" -gt 0 ] || [ "$cr_vfail" -gt 0 ]; then
        err "续签完成: 成功 ${cr_ok}, 失败 ${cr_fail}, 复验失败 ${cr_vfail}"
        return 1
    fi
    success "续签完成: 成功 ${cr_ok} 张, 复验全部通过"
    return 0
}

cmd_auto() {
    ca_yes=0
    # 解析剩余选项
    set -- $AUTO_ARGS
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes) ca_yes=1; shift ;;
            -d|--days) THRESHOLD_DAYS="$2"; shift 2 ;;
            -d*) THRESHOLD_DAYS="${1#-d}"; shift ;;
            [0-9]*) THRESHOLD_DAYS="$1"; shift ;;   # 兼容旧用法: ./renew.sh -d 60
            *) die "未知参数: $1 (auto 支持: -d 天数, -y 免确认)" ;;
        esac
    done

    info "自动续签模式 (阈值: ${THRESHOLD_DAYS} 天, 双证书成对续签)"

    # 按层级顺序找出需要续签的证书 (含已过期/即将过期/文件缺失)
    ca_list=$(reg | awk -F'|' '{print $1}' | while IFS= read -r ca_n; do
        if [ ! -f "${ca_n}.crt" ]; then
            # 证书文件缺失, 但私钥和配置都在 => 可以直接签发
            if [ -f "${ca_n}.key" ] && [ -f "${ca_n}.cnf" ]; then
                echo "$ca_n"
            fi
            continue
        fi
        if valid_within "${ca_n}.crt" "$THRESHOLD_DAYS"; then
            :
        else
            echo "$ca_n"
        fi
    done | while IFS= read -r ca_n; do
        # 双证书成对展开
        echo "$ca_n"
        ca_p=$(pair_of "$ca_n")
        [ -n "$ca_p" ] && echo "$ca_p"
    done | awk '!seen[$0]++')

    if [ -z "$ca_list" ]; then
        success "没有证书在 ${THRESHOLD_DAYS} 天内到期, 无需续签"
        return 0
    fi

    info "以下证书需要续签 (实体双证书自动成对):"
    for ca_n in $ca_list; do
        if [ -f "${ca_n}.crt" ]; then
            printf "  - %s (剩余 %s 天)\n" "$ca_n" "$(days_left "${ca_n}.crt")"
        else
            printf "  - %s (证书文件缺失, 将重新签发)\n" "$ca_n"
        fi
    done

    if [ "$ca_yes" -ne 1 ]; then
        printf "确认继续? [y/N]: "
        read -r ca_confirm
        case "$ca_confirm" in
            y|Y|yes|YES) ;;
            *) info "已取消"; return 0 ;;
        esac
    fi

    ca_ok=0
    ca_fail=0
    for ca_n in $ca_list; do
        if renew_one "$ca_n" ""; then
            ca_ok=$((ca_ok+1))
        else
            ca_fail=$((ca_fail+1))
        fi
    done

    # 重建链文件
    info "重建链文件..."
    build_chains

    printf '%s\n' ""
    if [ "$ca_fail" -gt 0 ]; then
        err "自动续签完成: 成功 ${ca_ok}, 失败 ${ca_fail}"
        return 1
    fi
    success "自动续签完成: 成功 ${ca_ok} 张, 链文件已重建"
    return 0
}

cmd_renew_all() {
    info "强制重新签发所有证书 (按层级顺序, 双证书相邻)..."
    ra_ok=0
    ra_fail=0
    for ra_n in $(reg | awk -F'|' '{print $1}'); do
        if renew_one "$ra_n" ""; then
            ra_ok=$((ra_ok+1))
        else
            ra_fail=$((ra_fail+1))
        fi
    done
    info "重建链文件..."
    build_chains
    printf '%s\n' ""
    if [ "$ra_fail" -gt 0 ]; then
        err "全部重签完成: 成功 ${ra_ok}, 失败 ${ra_fail}"
        return 1
    fi
    success "全部重签完成: 成功 ${ra_ok} 张"
    return 0
}

usage() {
    cat <<'EOF'
铜锁国密双证书重新签发工具 (POSIX sh, http 链 ×1)

用法:
  ./renew.sh <命令> [参数]

命令:
  check  [证书...]          检查有效期/证书链/私钥匹配/链文件/双证书同步 (默认全部)
  renew  <证书...> [-d N]   重新签发指定证书 (保留私钥), N 为有效期天数
  auto   [-d N] [-y]        自动续签 N 天内到期的证书 (默认 30 天, 双证书成对续签)
  renew-all                 强制重新签发所有证书
  verify [证书...]          验证证书链与私钥匹配 (默认全部)
  list                      列出证书清单
  chains                    重建所有链文件
  help                      显示本帮助

双证书规则:
  每个实体有 sign (签名) 和 enc (加密) 两张证书, 私钥独立。
  ./renew.sh renew hserver        -> 成对续签 hserver_sign + hserver_enc
  ./renew.sh renew hserver_sign   -> 只续签签名证书
  ./renew.sh check hserver        -> 检查 hserver 双证书
  auto 模式下任一张到期即成对续签; check 会对不同步的双证书告警。

兼容旧用法:
  ./renew.sh --check              等同 check
  ./renew.sh -c hserver_sign.crt  等同 renew hserver_sign
  ./renew.sh --force-all          等同 renew-all
  ./renew.sh -d 60                等同 auto -d 60

示例:
  ./renew.sh check                    # 检查全部证书
  ./renew.sh check hserver            # 只检查 hserver 双证书
  ./renew.sh renew hserver            # 成对续签 hserver 双证书 (默认 365 天)
  ./renew.sh renew hserver_sign -d 730 # 只续签签名证书, 有效期 730 天
  ./renew.sh auto -d 60 -y            # 续签 60 天内到期的证书, 免确认 (适合 cron)
  ./renew.sh verify hserver           # 验证 hserver 双证书的链与私钥
  ./renew.sh chains                   # 只重建链文件

说明:
  - 续签保留原有私钥; CA 用同一私钥续签后, 已签发的下级证书仍然有效
  - 签发使用 SM2 密钥 + SM3 摘要; DN 优先继承旧证书, 旧证书缺失时用内置默认值
  - cnf (root/intermediate/http-authority/hserver_sign/...) 由 mkcert.sh 统一
    生成, 续签前请确认已运行过 mkcert.sh; 续签与 mkcert.sh 共用 <CA>.srl
    的 serial 文件 (serial 连续)
  - 所有 SM2 签名强制 sm2_id=1234567812345678 (GM/T 标准值, 与 mkcert.sh 一致),
    续签后的证书可被 Go gmsm / 原生 OpenSSL 按标准 ID 校验
    (SM2_SIGOPT=0 可关闭强制)
  - 续签前旧证书自动备份到 backup/ 目录
  - 续签后自动重建 root-intermediate-chain.crt / http-full-chain.crt / *-chain.crt
  - check 退出码: 0 全部正常, 1 有证书需要处理 (可用于 cron 告警)
EOF
}

# ============================================================
# 主入口
# ============================================================

main() {
    # 兼容旧版参数风格
    case "$1" in
        --check|-check) shift; set -- check "$@" ;;
        --force-all|-force-all) shift; set -- renew-all "$@" ;;
        -c|--cert) shift; set -- renew "$@" ;;
        -d|--days) shift; set -- auto "$@" ;;
    esac

    if [ $# -eq 0 ]; then
        usage
        exit 0
    fi

    command="$1"
    shift

    case "$command" in
        check)
            # 提取 -d 阈值 (其余参数原样传给 cmd_check)
            cc_extra=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    -d|--days) THRESHOLD_DAYS="$2"; shift 2 ;;
                    -d*) THRESHOLD_DAYS="${1#-d}"; shift ;;
                    *) cc_extra="$cc_extra $1"; shift ;;
                esac
            done
            # shellcheck disable=SC2086
            set -- $cc_extra
            cmd_check "$@"
            ;;
        renew)
            cmd_renew "$@"
            ;;
        auto)
            AUTO_ARGS="$*"
            cmd_auto
            ;;
        renew-all|force-all)
            cmd_renew_all
            ;;
        verify)
            cmd_verify "$@"
            ;;
        list|ls)
            cmd_list
            ;;
        chains)
            cmd_chains
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            # 未知命令: 若看起来像证书名, 当作 renew 处理 (./renew.sh hserver)
            if [ -n "$(reg_lookup "$(norm_name "$command")")" ] || [ -n "$(reg_lookup "$(norm_name "$command")_sign")" ]; then
                cmd_renew "$command" "$@"
            else
                err "未知命令: $command (使用 ./renew.sh help 查看帮助)"
                exit 1
            fi
            ;;
    esac
}

# 环境检查
command -v "$TONGSUO_BIN" >/dev/null 2>&1 || die "未找到 $TONGSUO_BIN 命令, 可用 TONGSUO_BIN=/path/to/tongsuo 指定路径"

main "$@"
