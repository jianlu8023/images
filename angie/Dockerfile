ARG CONSOLE_LIGHT_VERSION=1.8.2

FROM alpine:3.22 AS builder

ARG CONSOLE_LIGHT_VERSION

ENV TONGSUO_VERSION=8.4.0 \
    TONGSUO_SHA256=a8ae0925d26de3b449f7a21767910cd41291bcd8 \
    ANGIE_VERSION=1.12.1 \
    ANGIE_SHA256=5f4f203be2aca6fe20770b489c720e46e51d337e521065e7e472b61e24e3d2f5 \
    PCRE2_VERSION=10.45 \
    PCRE2_SHA256=0e138387df7835d7403b8351e2226c1377da804e0737db0e071b48f07c9d12ee \
    CONSOLE_LIGHT_SHA256=ab6ed43e05af3a81176bc221dec105ba83bbbb982f2eda687bb64960c999b517

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    linux-headers \
    git \
    perl \
    make \
    curl \
    cmake \
    pcre2-dev \
    zlib-dev \
    libxml2-dev \
    libxslt-dev

WORKDIR /tmp

# Clone Tongsuo
RUN git init tongsuo-$TONGSUO_VERSION \
    && git -C tongsuo-$TONGSUO_VERSION remote add origin https://github.com/tongsuo-project/tongsuo.git \
    && git -C tongsuo-$TONGSUO_VERSION fetch --depth 1 origin $TONGSUO_SHA256 \
    && git -C tongsuo-$TONGSUO_VERSION checkout --detach FETCH_HEAD

# Download and extract Angie source（校验 SHA256）
RUN curl -fL -o angie-$ANGIE_VERSION.tar.gz \
    https://download.angie.software/files/angie-$ANGIE_VERSION.tar.gz \
    && echo "$ANGIE_SHA256  angie-$ANGIE_VERSION.tar.gz" | sha256sum -c - \
    && tar -xzf angie-$ANGIE_VERSION.tar.gz

# Download and extract PCRE2 source (built statically with JIT for regex performance, 校验 SHA256)
RUN curl -fL -o pcre2-$PCRE2_VERSION.tar.gz \
    https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz \
    && echo "$PCRE2_SHA256  pcre2-$PCRE2_VERSION.tar.gz" | sha256sum -c - \
    && tar -xzf pcre2-$PCRE2_VERSION.tar.gz

# angie-console-light 是纯前端产物（官方已提供预编译包，校验 SHA256）
RUN curl -fL -o angie-console-light.tar.gz \
    https://download.angie.software/files/angie-console-light/angie-console-light-$CONSOLE_LIGHT_VERSION.tar.gz \
    && echo "$CONSOLE_LIGHT_SHA256  angie-console-light.tar.gz" | sha256sum -c - \
    && tar -xzf angie-console-light.tar.gz

# Clone third-party dynamic module sources
RUN git clone --recurse-submodules --depth 1 \
        https://github.com/google/ngx_brotli.git \
    && git clone --depth 1 \
        https://github.com/openresty/headers-more-nginx-module.git \
    && git clone --depth 1 \
        https://github.com/openresty/echo-nginx-module.git \
    && git clone --depth 1 \
        https://github.com/yaoweibin/ngx_http_substitutions_filter_module.git \
    && git clone --depth 1 \
        https://github.com/nginx-modules/ngx_cache_purge.git \
    && git clone --depth 1 \
        https://github.com/arut/nginx-dav-ext-module.git \
    && git clone --depth 1 \
        https://github.com/simpl/ngx_devel_kit.git \
    && git clone --depth 1 \
        https://github.com/openresty/set-misc-nginx-module.git

# Build brotli C library (required by ngx_brotli filter module)
RUN cd /tmp/ngx_brotli/deps/brotli \
    && mkdir out && cd out \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && cmake --build . -j$(nproc)

# Configure and build Angie with NTLS support
WORKDIR /tmp/angie-$ANGIE_VERSION

# ------------------------------------------------------------------------------
# 构建 1/2 —— 正式版（angie-nodebug）
# --builddir 让两次构建互不干扰；--feature-cache 复用 OS 特性探测结果，加速第二次 configure
# 注意：顶层 Makefile 由 configure 生成且会被下一次 configure 覆盖，
#       所以每次 configure 后必须立刻执行对应的 make / make install
# ------------------------------------------------------------------------------
RUN ./configure \
    --prefix=/etc/angie \
    --conf-path=/etc/angie/angie.conf \
    --error-log-path=/var/log/angie/error.log \
    --http-log-path=/var/log/angie/access.log \
    --lock-path=/run/angie.lock \
    --modules-path=/usr/lib/angie/modules \
    --pid-path=/run/angie.pid \
    --sbin-path=/usr/sbin/angie \
    --http-acme-client-path=/var/lib/angie/acme \
    --http-client-body-temp-path=/var/cache/angie/client_temp \
    --http-fastcgi-temp-path=/var/cache/angie/fastcgi_temp \
    --http-proxy-temp-path=/var/cache/angie/proxy_temp \
    --http-scgi-temp-path=/var/cache/angie/scgi_temp \
    --http-uwsgi-temp-path=/var/cache/angie/uwsgi_temp \
    --user=angie \
    --group=angie \
    --with-file-aio \
    --with-http_acme_module \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-mail \
    --with-mail_ssl_module \
    --with-stream \
    --with-stream_acme_module \
    --with-stream_mqtt_preread_module \
    --with-stream_rdp_preread_module \
    --with-stream_realip_module \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-threads \
    --with-pcre=../pcre2-$PCRE2_VERSION \
    --with-pcre-jit \
    --with-ld-opt='-Wl,--as-needed,-O1,--sort-common -Wl,-z,pack-relative-relocs' \
    --with-openssl=../tongsuo-$TONGSUO_VERSION \
    --with-openssl-opt=enable-ntls \
    --with-ntls \
    --builddir=objs-nodebug \
    --feature-cache=../angie-feature-cache \
    --add-dynamic-module=../ngx_brotli \
    --add-dynamic-module=../headers-more-nginx-module \
    --add-dynamic-module=../echo-nginx-module \
    --add-dynamic-module=../ngx_http_substitutions_filter_module \
    --add-dynamic-module=../ngx_cache_purge \
    --add-dynamic-module=../nginx-dav-ext-module \
    --add-dynamic-module=../ngx_devel_kit \
    --add-dynamic-module=../set-misc-nginx-module \
    && make -j$(nproc) \
    && make install DESTDIR=/tmp/angie-install \
    && mv /tmp/angie-install/usr/sbin/angie /tmp/angie-install/usr/sbin/angie-nodebug \
    && ln -s angie-nodebug /tmp/angie-install/usr/sbin/angie

# ------------------------------------------------------------------------------
# 构建 2/2 —— 调试版（angie-debug，--with-debug 开启 NGX_DEBUG）
# 只要二进制，不再执行 make install，避免覆盖上一轮已安装的文件
# ------------------------------------------------------------------------------
RUN ./configure \
    --prefix=/etc/angie \
    --conf-path=/etc/angie/angie.conf \
    --error-log-path=/var/log/angie/error.log \
    --http-log-path=/var/log/angie/access.log \
    --lock-path=/run/angie.lock \
    --modules-path=/usr/lib/angie/modules \
    --pid-path=/run/angie.pid \
    --sbin-path=/usr/sbin/angie \
    --http-acme-client-path=/var/lib/angie/acme \
    --http-client-body-temp-path=/var/cache/angie/client_temp \
    --http-fastcgi-temp-path=/var/cache/angie/fastcgi_temp \
    --http-proxy-temp-path=/var/cache/angie/proxy_temp \
    --http-scgi-temp-path=/var/cache/angie/scgi_temp \
    --http-uwsgi-temp-path=/var/cache/angie/uwsgi_temp \
    --user=angie \
    --group=angie \
    --with-debug \
    --with-file-aio \
    --with-http_acme_module \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-mail \
    --with-mail_ssl_module \
    --with-stream \
    --with-stream_acme_module \
    --with-stream_mqtt_preread_module \
    --with-stream_rdp_preread_module \
    --with-stream_realip_module \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-threads \
    --with-pcre=../pcre2-$PCRE2_VERSION \
    --with-pcre-jit \
    --with-ld-opt='-Wl,--as-needed,-O1,--sort-common -Wl,-z,pack-relative-relocs' \
    --with-openssl=../tongsuo-$TONGSUO_VERSION \
    --with-openssl-opt=enable-ntls \
    --with-ntls \
    --builddir=objs-debug \
    --feature-cache=../angie-feature-cache \
    --add-dynamic-module=../ngx_brotli \
    --add-dynamic-module=../headers-more-nginx-module \
    --add-dynamic-module=../echo-nginx-module \
    --add-dynamic-module=../ngx_http_substitutions_filter_module \
    --add-dynamic-module=../ngx_cache_purge \
    --add-dynamic-module=../nginx-dav-ext-module \
    --add-dynamic-module=../ngx_devel_kit \
    --add-dynamic-module=../set-misc-nginx-module \
    && make -j$(nproc) \
    && cp objs-debug/angie /tmp/angie-install/usr/sbin/angie-debug


FROM alpine:3.22 AS product

ARG CONSOLE_LIGHT_VERSION

LABEL org.opencontainers.image.authors="Jianlu <jianlu8023@gmail.com>; Release Engineering Team <devops@tech.wbsrv.ru>"

# Install runtime dependencies and create angie user
RUN set -x \
    && apk add --no-cache bash ca-certificates curl pcre2 zlib tzdata \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    && adduser -D -H -u 101 -s /sbin/nologin angie

# Copy Angie installation from builder
COPY --from=builder /tmp/angie-install/ /

# angie-console-light 静态前端资源
COPY --from=builder /tmp/angie-console-light-$CONSOLE_LIGHT_VERSION/html/ \
    /usr/share/angie-console-light/html/

# Tongsuo is statically linked (.a archives), no runtime library copy needed

# Clean up .default files, relocate html, create modules symlink and http.d/stream.d directories
RUN rm -f /etc/angie/*.default \
    && mkdir -p /usr/share/angie/html \
    && mv /etc/angie/html/* /usr/share/angie/html/ \
    && rmdir /etc/angie/html \
    && ln -s /usr/lib/angie/modules /etc/angie/modules \
    && mkdir -p /etc/angie/http.d /etc/angie/stream.d

# Create necessary directories and set permissions
RUN mkdir -p /var/cache/angie /var/log/angie /run/angie /var/lib/angie/acme \
    && chown -R angie:angie /var/cache/angie /var/log/angie /run/angie /var/lib/angie \
        /etc/angie /usr/share/angie /usr/share/angie-console-light

# Redirect logs to stdout/stderr
RUN ln -sf /dev/stdout /var/log/angie/access.log \
    && ln -sf /dev/stderr /var/log/angie/error.log

# logrotate 配置 + 每日定时任务脚本
# 默认镜像内没有 cron 守护进程，因此 logrotate 不会自动运行；
# 需要归档时自行拉起 crond，或用外部 cron 执行 `docker exec <ctr> logrotate /etc/logrotate.conf`
COPY logrotate.d/angie /etc/logrotate.d/angie
RUN mkdir -p /etc/periodic/daily /var/lib/logrotate \
    && printf '#!/bin/sh\n[ -x /usr/sbin/logrotate ] || exit 0\n/usr/sbin/logrotate -s /var/lib/logrotate/logrotate.status /etc/logrotate.conf\nexit 0\n' > /etc/periodic/daily/logrotate \
    && chmod +x /etc/periodic/daily/logrotate

# Copy configuration files
COPY angie.conf /etc/angie/
COPY http.d/default.conf /etc/angie/http.d/
# NTLS 参考站点模板
COPY http.d/ntls-gm.conf.example /etc/angie/http.d/
COPY stream.d/example.conf /etc/angie/stream.d/

EXPOSE 80 443

STOPSIGNAL SIGQUIT

# 健康检查用 /status/ 的 HTTP 响应码判断存活。
# default.conf 对 /status/ 限了 127.0.0.1 访问，容器外访问返回 403，
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD sh -c 'code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1/status/ || echo 000); [ "$code" != "000" ]'

CMD ["angie", "-g", "daemon off;"]
