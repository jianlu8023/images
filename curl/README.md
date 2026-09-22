# curl HTTP/3 镜像 —— 5 种 TLS 后端对比 + Rustls 变体

本目录用 **6 个独立的 Dockerfile** 分别构建 curl：前 5 个对应支持 HTTP/3 的
不同 TLS 后端（QUIC 的加密层由各自的 TLS 库实现），第 6 个是 **Rustls
变体（不含 HTTP/3**，因为 ngtcp2 没有 rustls 加密后端）：

| Dockerfile | 镜像 tag | TLS 后端 | ngtcp2 加密后端 |
|---|---|---|---|
| `Dockerfile-openssl` | `curl:8.22.0-h3-openssl` | OpenSSL 3.5.8（官方主库，原生 QUIC API） | `libngtcp2_crypto_ossl`（`SSL_set_quic_tls_cbs`） |
| `Dockerfile-wolfssl` | `curl:8.22.0-h3-wolfssl` | wolfSSL 5.9.2（`--enable-quic`） | `libngtcp2_crypto_wolfssl` |
| `Dockerfile-gnutls` | `curl:8.22.0-h3-gnutls` | GnuTLS 3.8.13（原生支持 QUIC） | `libngtcp2_crypto_gnutls` |
| `Dockerfile-awslc` | `curl:8.22.0-h3-awslc` | AWS-LC 5.9.0（BoringSSL 分支，OpenSSL API 兼容） | `libngtcp2_crypto_boringssl`（`OPENSSL_IS_AWSLC`） |
| `Dockerfile-boringssl` | `curl:8.22.0-h3-boringssl` | BoringSSL 0.20260730.0（Google 原版） | `libngtcp2_crypto_boringssl`（`OPENSSL_IS_BORINGSSL`） |
| `Dockerfile-rustls` | `curl:8.22.0-rustls` | Rustls 0.23（经 rustls-ffi 0.15.3，Rust 实现） | —（无 HTTP/3） |

镜像 tag 格式：H3 变体 `curl:<curl版本>-h3-<后端>`，Rustls 变体
`curl:<curl版本>-rustls`——一眼看出基于哪个 curl 版本、是否有 HTTP/3、用的
哪个 TLS 后端（`build-all.sh` / `bench.sh` / `test-rustls.sh` 从 Dockerfile 的
`ARG CURL_VERSION` 自动读取拼 tag，升版后无需改脚本）。

> **为什么 Rustls 变体没有 HTTP/3**：curl 的 QUIC 路径一律走 ngtcp2 +
> nghttp3，而 ngtcp2 的加密后端只有 OpenSSL/BoringSSL/GnuTLS/wolfSSL/picotls
> （v1.25.0 源码已确认无 rustls 后端）；Rustls 只能作 curl 的 TLS 后端
> （HTTPS），不能供 ngtcp2 做 QUIC 加密。因此该变体定位为「默认 curl +
> Rustls」，用于非 H3 场景的 TLS 后端对比。

## 功能定位：默认 curl 全功能 + HTTP/3

6 个镜像的目标一致：**保留发行版默认 curl 的全部功能**（参考 Ubuntu 22.04
默认 curl 8.5.0 的 Protocols/Features 行），前 5 个额外加上 HTTP/3。
构建时安装对应 alpine `*-dev` 包并在 `./configure` 全部启用：

- `--with-brotli` / `--with-zstd` → 压缩 brotli / zstd（`--compressed` 可用）
- `--with-libssh` → scp / sftp（libssh 0.11.2）
- `--with-libidn2` → IDN（国际化域名）
- `--with-libpsl` → PSL（公共后缀列表，cookie 域解析）
- `--with-gssapi`（alpine krb5-dev）→ GSS-API / SPNEGO / Kerberos
- `--enable-ntlm` → NTLM（5 个 H3 变体中 DES 分别由各 TLS 后端提供，见下方踩坑；
  Rustls 变体由 curl 内置实现，因 Rustls 无 DES）
- `--enable-smb` → smb / smbs（依赖 NTLM）
- 默认开启的 HTTP2 / ws / wss / mqtt / mqtts / rtsp / ipfs / ipns 等保持不变

实测 `curl -V`（5 个 H3 变体一致，仅 TLS 后端名不同）：

```
Protocols: dict file ftp ftps gopher gophers http https imap imaps ipfs ipns ldap ldaps mqtt mqtts pop3 pop3s rtsp scp sftp smb smbs smtp smtps telnet tftp ws wss
Features: alt-svc AsynchDNS brotli GSS-API HSTS HTTP2 HTTP3 HTTPS-proxy IDN IPv6 Kerberos Largefile libz NTLM PSL SPNEGO SSL threadsafe UnixSockets zstd
```

Rustls 变体：Features 行以 `Rustls` 替代 `SSL` 之外的后端标识、**无 HTTP3**，
其余功能项相同（build 期与 runtime 期均有 `curl -V` 门禁，含「必须无 HTTP3」
的负向检查）。

> 与默认发行版 curl 的差异说明：
> - `librtmp/rtmp`：curl 8.22.0 已彻底移除 librtmp 后端（上游 8.0 起弃用、
>   8.22 删除源码，alpine 3.22 仓库亦无 librtmp 包），**任何 curl 8.22 构建
>   都拿不到**，非本镜像裁剪；
> - `TLS-SRP`：上游 8.19 起移除（`--tlsauthtype SRP` 不再存在），同理；
> - 其余 Protocols/Features 与默认 curl 对齐，另加 `HTTP3`。

构建阶段还内置了**功能完整性门禁**（build 期与 runtime 期各一道）：
`curl -V` 必须含 HTTP3/HTTP2/brotli/zstd/libssh/libidn2/libpsl/GSS-API/
Kerberos/SPNEGO/NTLM/IDN/PSL/ldaps/smb，且 `ldd curl` 无 `not found`，
任一不满足构建即失败。

## 统一版本基线

所有变体使用 **同一套版本**（取自 curl 8.22.0 官方 CI 的同款组合），
保证尺寸/性能差异只来自 TLS 后端本身：

| 组件 | 版本 |
|---|---|
| curl | 8.22.0 |
| ngtcp2 | 1.25.0（仅 5 个 H3 变体） |
| nghttp3 | 1.18.0（仅 5 个 H3 变体） |
| 运行时基础镜像 | alpine:3.22 |
| 构建基础镜像 | alpine:3.22 |
| rustls-ffi | 0.15.3（仅 Rustls 变体，rustls 0.23 / aws-lc-rs provider） |

各 H3 变体唯一的差异是 TLS 库及其版本：OpenSSL 3.5.8 /
wolfSSL 5.9.2 / GnuTLS 3.8.13 / AWS-LC 5.9.0 / BoringSSL 0.20260730.0。

> 注意：curl 8.19.0 起移除了 OpenSSL-QUIC 直连后端，5 个 H3 变体的 HTTP/3 均走
> ngtcp2 + nghttp3，`curl -V` 的 `Features` 行均含 `HTTP3`（Rustls 变体无 HTTP/3，
> 见文首说明）。

## 构建

上游源码 tarball 由 Dockerfile 在构建时从官方源（GitHub release / tag 归档 /
gnupg.org 镜像）wget 下载并逐个做 sha256 校验（校验失败即构建失败），
**不需要本地准备 `src/` 目录**，任何机器 clone 本目录即可构建：

```sh
./build-all.sh            # 构建全部 6 个镜像（含 rustls）
./build-all.sh openssl    # 只构建某个变体（可多个：./build-all.sh rustls awslc）
./build-all.sh test       # 构建后起本地 caddy H3 server 并实测 --http3-only
                          #（rustls 无 H3，不参与；功能验证用 ./test-rustls.sh）
./test-rustls.sh          # 单独验证 rustls 变体（https 实测 + 信任 CA + curl -V 自检）
```

## 更新组件版本

`update-versions.sh` 自动解析版本、下载官方 tarball、计算 sha256，并批量同步 6 个 Dockerfile
（含下载 URL / 文件名里写死的版本号）：

```sh
./update-versions.sh curl 8.23.0        # 指定版本（同步改全部 6 个 Dockerfile）
./update-versions.sh openssl latest     # 自动取最新（限定当前小版本系列内，如 3.5.x）
./update-versions.sh ngtcp2 1.25.1 --dry-run   # 只解析 + 下载 + 算 sha256，不写文件（ngtcp2 只改 5 个 H3 变体）
./update-versions.sh boringssl latest --build   # 更新后立即构建受影响变体
./update-versions.sh rustls-ffi latest          # Rustls 变体的 rustls-ffi 升版
```

说明：
- `latest` 按组件分别解析：curl/ngtcp2/nghttp3/wolfssl/awslc/boringssl 取 GitHub 最大 tag；
  openssl 与 gnutls 限定在当前小版本系列内（如 openssl 3.5.x、gnutls v3.8 目录），
  避免直接跳到不兼容的大版本；跨大版本请显式给版本号。
- 下载失败（版本不存在）时不改任何文件；成功后打印 diff。
- 新版本可能改变 configure 参数或依赖，更新后务必 `./build-all.sh <变体>` +
  `./build-all.sh test`（rustls 变体用 `./test-rustls.sh`）验证（踩坑记录见
  HANDOFF.md 第 6 节）。

各变体的源码来源（均固定版本 + sha256）：

| 组件 | 来源 |
|---|---|
| curl 8.22.0 | GitHub release `curl/curl`（`curl-8_22_0`） |
| ngtcp2 1.25.0 / nghttp3 1.18.0 | GitHub release `ngtcp2/ngtcp2`、`ngtcp2/nghttp3` |
| OpenSSL 3.5.8 | GitHub release `openssl/openssl` |
| wolfSSL 5.9.2 | GitHub `wolfSSL/wolfssl` tag `v5.9.2-stable` 归档 |
| GnuTLS 3.8.13 | `www.gnupg.org/ftp/gcrypt/gnutls/v3.8/`（GnuTLS 官方 FTP 镜像） |
| AWS-LC 5.9.0 | GitHub `aws/aws-lc` tag `v5.9.0` 归档 |
| BoringSSL 0.20260730.0 | GitHub `google/boringssl` tag `0.20260730.0` 归档 |
| rustls-ffi 0.15.3 | GitHub `rustls/rustls-ffi` tag `v0.15.3` 归档（官方 docs/RUSTLS.md 同款来源） |

> 注意：ngtcp2 官方 release tarball 自带已生成的 `configure`（无需 autotools
> 再生成），因此 Dockerfile 里 ngtcp2 一步直接 `./configure`。

或手动：

```sh
docker buildx build --load -f Dockerfile-openssl -t curl:8.22.0-h3-openssl .
docker run --rm curl:8.22.0-h3-openssl curl -V   # Features 行应有 HTTP3

docker buildx build --load -f Dockerfile-rustls -t curl:8.22.0-rustls .
docker run --rm curl:8.22.0-rustls curl -V       # Features 行应有 Rustls、无 HTTP3
```

## 实测

- 功能：`./build-all.sh test` 会在 `h3net` 网络上启动 `caddy:2.11-alpine`
  作为 HTTP/3 server（自签名证书），各镜像执行
  `curl --http3-only -k https://h3.local:8443/`，全部返回 `proto=3 code=200`
  （含真实 QUIC/TLS 握手）。
- 性能：`./bench.sh [runs]` —— 10MB 下载的 TTFB/总耗时/吞吐 + 20 次小请求
  TTFB（首请求含 QUIC 握手，其余复用连接）。仅 5 个 H3 变体参与（rustls 无 H3）。

实测（本机 Docker 网络，caddy 172.28.99.10:8443，`./bench.sh 3` 取中位数，
全功能版，5 个 H3 变体）：

| 变体 | 镜像大小 | 10MB 吞吐（MB/s） | 10MB 总耗时 | TTFB 首请求(含QUIC握手) | 小请求复用连接 |
|---|---|---|---|---|---|
| openssl | 60.7 MB | ~203 | ~49 ms | 8.3 ms | 0.4 ms |
| wolfssl | 39.2 MB | ~67 | ~150 ms | 9.7 ms | 0.3 ms |
| gnutls | 54 MB | ~212 | ~47 ms | 6.3 ms | 0.4 ms |
| awslc | 43 MB | ~131 | ~78 ms | 35.0 ms | 0.2 ms |
| boringssl | 70.8 MB | ~190 | ~53 ms | 7.6 ms | 0.3 ms |

观察（仅本机内网、非公网，仅供参考）：
- 复用连接后的稳态延迟 5 个后端都 ≈ 0.3–0.4 ms，差异主要在**握手/首字节**
  和**吞吐**：gnutls / boringssl / openssl 第一梯队；awslc 首字节偏高；
  wolfSSL 吞吐约为其它后端 1/3（wolfSSL 该构建的 QUIC 路径开销更大）。
- 镜像体积与 TLS 库实现复杂度相关，与性能无直接对应（wolfSSL 最小但最慢）。

> 本机出网 UDP 被限制，公网 H3 站点不可达，故性能测试全部在本地 Docker
> 网络（caddy）上进行，用于横向对比同一网络环境下不同 TLS 后端的差异。

## 各变体要点 / 踩坑记录

- **全功能依赖（5 变体通用）**：brotli-dev / zstd-dev / libssh-dev /
  libidn2-dev / libpsl-dev / openldap-dev / krb5-dev 进构建期，运行期对应
  brotli-libs / zstd-libs / libssh / libidn2 / libpsl / libldap / krb5-libs；
  ldap/ldaps 无需额外 flag（openldap-dev 在位即默认启用）；
  GSS-API 用 `--with-gssapi`（经 mit-krb5-gssapi pkg-config 检测）。
  **libssh 0.11.2 运行期链接系统 `libcrypto.so.3`**（apk 元数据不声明依赖），
  故非 openssl 变体的运行期也要装 `openssl` 运行时包，`ldd` 门禁会兜底。
- **openssl**：OpenSSL 3.5+ 自带 QUIC TLS API（`SSL_set_quic_tls_cbs`），
  ngtcp2 的 OpenSSL 后端自动选中。构建需 `linux-headers`（`linux/mman.h`）。
  NTLM 的 DES 来自 OpenSSL 兼容层 `openssl/des.h` 的 `DES_ecb_encrypt`。
- **wolfssl**：需要 `--enable-quic --enable-opensslall --enable-aesecb`，
  否则 `libngtcp2_crypto_wolfssl` 引用的 `wolfSSL_EVP_aes_*_ecb` 等符号缺失，
  curl 链接报 undefined reference。
  **NTLM 坑**：wolfSSL 的 `wc_Des_EcbEncrypt` 同时需要 `--enable-des3`
  **和** `-DWOLFSSL_DES_ECB`（`CFLAGS="-DWOLFSSL_DES_ECB" ./configure`）；
  只开 `--enable-des3` 时该符号仍不编译（`wc_Des_EcbEncrypt... no`），
  curl 会静默放弃 NTLM（`#error "cannot compile NTLM..."` 由配置期规避）。
- **gnutls**：alpine 3.22 无 `unistring-dev` 包，改用 GnuTLS 自带的
  `--with-included-unistring`；运行时需 libtasn1/nettle/p11-kit/gmp。
  NTLM 的 DES 由 alpine 的 nettle 提供（GnuTLS 变体经 `nettle_md5_init` 检测）。
- **awslc**：CMake 构建需 `-DDISABLE_GO=ON`（容器内无 Go）；AWS-LC 自带
  OpenSSL 兼容 shim（`openssl.pc` 等），故 curl 直接用 `--with-openssl=/opt/h3`。
  NTLM 的 DES 来自 AWS-LC 的 `openssl/des.h` `DES_ecb_encrypt`（配置期
  “checking for DES support in OpenSSL... yes”）。
- **boringssl**：源码用 GitHub tag 归档（自带顶层目录 `boringssl-<version>/`，
  直接解压即可）；ngtcp2 用 `--with-boringssl` 并提供 `BORINGSSL_CFLAGS/LIBS`
  指向安装前缀。NTLM 的 DES 来自 BoringSSL 兼容层 `openssl/des.h`
  （DEPRECATED 但仍导出 `DES_ecb_encrypt`）。
- **rustls**：
  - **无 HTTP/3**（见文首说明）；`curl -V` 门禁里显式检查「不得出现 HTTP3」。
  - 工具链用 alpine 官方 apk 包 `rust`（1.87.0，满足 rustls-ffi 0.15.3 的
    `rust-version=1.85`）+ `cargo-c`（0.10.13，提供 `cargo capi install`），
    不装 rustup；cargo 依赖走阿里云 crates 镜像（`/usr/local/cargo/config.toml`
    的 sparse index）。
  - 构建流程：`cargo capi install --release --prefix=/opt/h3` 编出
    `librustls.so` + 头文件 + `rustls.pc`（crypto provider 默认 aws-lc-rs，
    musl 下无预编译产物，由 cmake 源码编译 → 构建期需 `cmake perl`）；
    再 `./configure --with-rustls=/opt/h3` 让 curl 经 pkg-config 找到它。
  - NTLM 的 DES：rustls 没有 DES，curl 在 USE_RUSTLS 下走 `#else` 内置
    实现（与 curl 上游设计一致）；SMB 依赖 NTLM，同样可用。
  - rustls 信任系统 CA（构建时 `--with-ca-bundle`）；`--cert-status`
    （OCSP 装订）rustls 暂不支持（上游实验性状态）。

