FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    TONGSUO_VERSION=8.5.0 \
    # tag 8.5.0 对应的 commit
    TONGSUO_SHA256=80cfbe3eb194a4d30da90742273c305ad4d096be

RUN sed -i "s/archive.ubuntu.com/mirrors.aliyun.com/g" /etc/apt/sources.list && \
    sed -i "s/security.ubuntu.com/mirrors.aliyun.com/g" /etc/apt/sources.list && \
    apt update && \
    apt install -y --no-install-recommends \
    build-essential git make perl \
    ca-certificates \
    libssl-dev zlib1g-dev \
    # enable-brotli / enable-zstd 需要系统依赖库的头文件和库
    libbrotli-dev libzstd-dev \
    zip unzip

WORKDIR /usr/local/src
RUN git init tongsuo-$TONGSUO_VERSION \
    && git -C tongsuo-$TONGSUO_VERSION remote add origin https://github.com/tongsuo-project/tongsuo.git \
    && git -C tongsuo-$TONGSUO_VERSION fetch --depth 1 origin $TONGSUO_SHA256 \
    && git -C tongsuo-$TONGSUO_VERSION checkout --detach FETCH_HEAD

WORKDIR /usr/local/src/tongsuo-$TONGSUO_VERSION

# --prefix 指定铜锁安装目录
# --openssldir 指定配置文件和证书文件的存放目录
# enable-xx 启用
# -no-shared 不生成.so文件 只生成.a文件
# -fPIC 生成位置无关代码 通常是编译动态库的要求
# -no-shared -fPIC 建议一起使用
# 若需要把外部依赖（brotli/zstd/zlib）也静态链接，使 product 镜像零运行时依赖：
#   1. builder 里先从源码编译 brotli/zstd 的 -fPIC 静态库（发行版 -dev 包自带的 .a 非 PIC，链不进 PIE）
#   2. 下方 config 追加：--with-brotli-lib=<含 brotlidec/brotlienc/brotlicommon .a 的目录> --with-zstd-lib=<含 libzstd.a 的目录>
#   3. 去掉 product 阶段 apt 里的 libbrotli1 libzstd1 运行时包
# enable-cert-compression 8.5.0版本前使用
# 目前支持的选项包括 enable-zlib、enable-brotli 以及 enable-zstd 8.5.0版本后使用
# enable-kyber enable-sm2dh-mlkem768-hybrid 8.5.0前开启pqc连接 no-kyber no-sm2dh-mlkem768-hybrid 禁用 8.5.0后默认开启
# enable-ml_dsa 开启ml-dsa-65 8.5.0前使用 8.5.0后默认开启
RUN ./config --prefix=/usr/local/tongsuo \
    --openssldir=/usr/local/tongsuo/ssl \
    -Wl,-rpath,/usr/local/tongsuo/lib \
    enable-ec_elgamal \
    enable-ntls \
    enable-sm2 \
    enable-sm3  \
    enable-sm4  \
    enable-brotli  \
    enable-zstd \
    enable-zlib \
    -fPIC \
    -no-shared && \
    make -j$(nproc) && \
    make install && \
    echo "/usr/local/tongsuo/lib" | tee /etc/ld.so.conf.d/tongsuo.conf && \
    echo "/usr/local/tongsuo/lib64" | tee -a /etc/ld.so.conf.d/tongsuo.conf && \
    ldconfig && \
    make clean


FROM ubuntu:22.04 AS product

# tongsuo 二进制（本体静态，-no-shared）+ openssldir（配置/证书目录）
# libbrotli1 libzstd1 是证书压缩（RFC8879）的运行时依赖，按上方注释改成全静态后可去掉这两个包
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates tzdata libbrotli1 libzstd1 \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# tongsuo 二进制（静态）+ openssldir（配置/证书目录）
COPY --from=builder /usr/local/tongsuo/bin/ /usr/local/tongsuo/bin/
COPY --from=builder /usr/local/tongsuo/include/ /usr/local/tongsuo/include/
COPY --from=builder /usr/local/tongsuo/ssl/ /usr/local/tongsuo/ssl/
COPY --from=builder /usr/local/tongsuo/lib64/ /usr/local/tongsuo/lib64/

ENV PATH=/usr/local/tongsuo/bin:$PATH \
    TZ=Asia/Shanghai

WORKDIR /workspace

CMD ["tongsuo","version","-a"]
