# openhitls

## 官方信息

```text
# github https://github.com/openhitls/openhitls.git
```

## 构建命令

```bash
docker build -t openhitls:0.4.0-alpha15-ubuntu .
```

## 验证

```bash
docker run --rm openhitls:0.4.0-alpha15-ubuntu                     # CMD: hitls version
docker run --rm openhitls:0.4.0-alpha15-ubuntu hitls dgst -md sm3  # 交互式输入做 SM3
```

## 参数说明

| 参数 | 说明 |
|------|------|
| `HITLS_VERSION` | 版本名（`0.4.0-alpha15`），仅用于源码目录命名 |
| `HITLS_SHA256` | 构建 commit（`defab80ad`，main HEAD，alpha15 后 4 个 commit） |
| `HITLS_BUILD_PROFILE=full` | 全量模块 BSL/CRYPTO/PKI/TLS/AUTH（可换 iso19790/none） |
| `HITLS_BUILD_SHARED/STATIC=ON` | 动态/静态库 |
| `HITLS_BUILD_EXE=ON` | 编译 hitls CLI（默认 OFF 只出库） |
| `HITLS_ASM_X8664=ON` | x86_64 汇编优化（.S 由 gcc 汇编，无需 nasm） |
| `CMAKE_INSTALL_PREFIX` | 安装目录 `/usr/local/hitls`（bin/lib/include） |
