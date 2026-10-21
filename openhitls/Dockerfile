FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    HITLS_VERSION=0.4.0-alpha15 \
    # tag openhitls-0.4.0-alpha15 后 4 个 commit（main HEAD）
    HITLS_SHA256=defab80ad228be747c52d722a7f27016b5bf126b

RUN sed -i "s/archive.ubuntu.com/mirrors.aliyun.com/g" /etc/apt/sources.list && \
    sed -i "s/security.ubuntu.com/mirrors.aliyun.com/g" /etc/apt/sources.list && \
    apt update && \
    apt install -y --no-install-recommends \
    build-essential git cmake \
    ca-certificates \
    openssl \
    pkg-config

WORKDIR /usr/local/src
RUN git init openhitls-$HITLS_VERSION \
    && git -C openhitls-$HITLS_VERSION remote add origin https://github.com/openhitls/openhitls.git \
    && git -C openhitls-$HITLS_VERSION fetch --depth 1 origin $HITLS_SHA256 \
    && git -C openhitls-$HITLS_VERSION checkout --detach FETCH_HEAD

WORKDIR /usr/local/src/openhitls-$HITLS_VERSION

# cmake 配置说明:
#   HITLS_BUILD_PROFILE=full      全量模块 BSL/CRYPTO/PKI/TLS/AUTH（默认）
#   HITLS_BUILD_EXE=ON            编译 hitls CLI（默认 OFF 只出库）
#   HITLS_ASM_X8664=ON            x86_64 汇编优化（.S 由 gcc 汇编，无需 nasm）
#   头文件安装到 <prefix>/include/hitls/<module>，库安装到 <prefix>/<CMAKE_INSTALL_LIBDIR>
RUN mkdir build && \
    cd build && \
    cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local/hitls \
    -DHITLS_BUILD_PROFILE=full \
    -DHITLS_BUILD_SHARED=ON \
    -DHITLS_BUILD_STATIC=ON \
    -DHITLS_BUILD_EXE=ON \
    -DHITLS_ASM_X8664=ON \
    -DHITLS_PLATFORM_ENDIAN=little && \
    make -j$(nproc) && \
    make install && \
    echo "/usr/local/hitls/lib" | tee /etc/ld.so.conf.d/hitls.conf && \
    ldconfig && \
    make clean


FROM ubuntu:22.04 AS product

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates tzdata \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# hitls 二进制（bin/hitls + 完整性文件 hitls.hmac）+ 动态库 + 头文件
COPY --from=builder /usr/local/hitls/bin/ /usr/local/hitls/bin/
COPY --from=builder /usr/local/hitls/include/ /usr/local/hitls/include/
COPY --from=builder /usr/local/hitls/lib/ /usr/local/hitls/lib/

RUN echo "/usr/local/hitls/lib" | tee /etc/ld.so.conf.d/hitls.conf && ldconfig

ENV PATH=/usr/local/hitls/bin:$PATH \
    TZ=Asia/Shanghai

WORKDIR /workspace

CMD ["hitls","version"]
