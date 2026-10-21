#!/usr/bin/env bash
# 三层 PKI (root -> intermediate -> app) + TLCP 双证书(签名/加密) 自签证书
# 全部使用 SM2 + SM3，运行在 openhitls 容器内: bash pki.sh
set -euo pipefail
# 产物写到 OUTDIR(默认当前目录)
cd "${OUTDIR:-.}"
CURVE="ec_paramgen_curve:sm2"
USERID="1234567812345678"   # SM2 用户ID

# ext 配置: CA 证书扩展
cat > v3_ca.cnf <<'EOF'
[v3_ca]
basicConstraints = CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
# ext 配置: 终端证书扩展(签名/加密)
cat > v3_sign.cnf <<'EOF'
[v3_sign]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
cat > v3_enc.cnf <<'EOF'
[v3_enc]
basicConstraints = CA:FALSE
keyUsage = critical,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

gen() { hitls genpkey -algorithm ec -pkeyopt "$CURVE" -out "$1.key"; }
csr() { hitls req -new -key "$1.key" -mdalg sm3 -userid "$USERID" -subj "$2" -out "$1.csr"; }
selfsign() { # root 自签: $1=name $2=days
  hitls x509 -req -in "$1.csr" -signkey "$1.key" -md sm3 -userid "$USERID" \
    -extfile v3_ca.cnf -extensions v3_ca -days "$2" -out "$1.crt";
}
casign() { # 由 CA 签发: $1=name $2=days $3=ca $4=extfile $5=section
  hitls x509 -req -in "$1.csr" -CA "$3.crt" -CAkey "$3.key" -md sm3 -userid "$USERID" \
    -extfile "$4" -extensions "$5" -days "$2" -out "$1.crt";
}

echo "== 1. root (自签 CA) =="
gen root;        csr root "/C=CN/O=openhitls/CN=openhitls-root"
selfsign root 3650

echo "== 2. intermediate (由 root 签, CA) =="
gen intermediate; csr intermediate "/C=CN/O=openhitls/CN=openhitls-intermediate"
casign intermediate 1830 root v3_ca.cnf v3_ca

echo "== 3. app 签名证书 (由 intermediate 签, 终端) =="
gen app_sign;    csr app_sign "/C=CN/O=openhitls/CN=app"
casign app_sign 365 intermediate v3_sign.cnf v3_sign

echo "== 4. app 加密证书 (由 intermediate 签, 终端, TLCP 双证书第二张) =="
gen app_enc;     csr app_enc "/C=CN/O=openhitls/CN=app"
casign app_enc 365 intermediate v3_enc.cnf v3_enc

echo "== 5. client 签名/加密证书 (TLCP 客户端也必须出示双证书) =="
gen client_sign; csr client_sign "/C=CN/O=openhitls/CN=client"
casign client_sign 365 intermediate v3_sign.cnf v3_sign
gen client_enc;  csr client_enc  "/C=CN/O=openhitls/CN=client"
casign client_enc 365 intermediate v3_enc.cnf v3_enc

echo "== 组装证书链 (app -> intermediate -> root) =="
cat app_sign.crt intermediate.crt root.crt > chain_sign.crt
cat app_enc.crt  intermediate.crt root.crt > chain_enc.crt

echo "== 校验 =="
for c in root intermediate app_sign app_enc; do
  printf "%-12s subject: %s\n" "$c" "$(hitls x509 -in $c.crt -subject -noout)"
  printf "            issuer: %s\n" "$(hitls x509 -in $c.crt -issuer -noout)"
done
hitls verify -CAfile root.crt -untrusted intermediate.crt -userid "$USERID" app_sign.crt 2>&1 | tail -1
hitls verify -CAfile root.crt -untrusted intermediate.crt -userid "$USERID" app_enc.crt 2>&1 | tail -1

echo "== 产物文件 =="
ls *.crt *.key
