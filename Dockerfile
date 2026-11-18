# syntax=docker/dockerfile:1
ARG NGINX_VERSION=1.31.8
ARG OPENAPPSEC_ATTACHMENT_REF=main
ARG BASE_IMAGE=debian:trixie-slim

###############################################################################
FROM ${BASE_IMAGE} AS builder
ARG NGINX_VERSION
ARG OPENAPPSEC_ATTACHMENT_REF
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git curl ca-certificates pkg-config patchelf binutils \
      libpcre2-dev zlib1g-dev libssl-dev libbrotli-dev libxml2-dev python3 \
    && rm -rf /var/lib/apt/lists/*

# Flags mirror the target F5 nginx-ingress build (minus F5-proprietary modules).
ENV NGINX_CC_OPT="-g -O2 -fstack-protector-strong -fstack-clash-protection -Wformat -Werror=format-security -fcf-protection -Wp,-D_FORTIFY_SOURCE=2 -fPIC" \
    NGINX_LD_OPT="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie"

WORKDIR /build
RUN curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" | tar xz \
 && mv "nginx-${NGINX_VERSION}" nginx-src

RUN git clone https://github.com/openappsec/attachment.git attachment \
 && git -C attachment checkout "${OPENAPPSEC_ATTACHMENT_REF}" \
 && git -C attachment submodule update --init --recursive

# Configure + build nginx once: gives us the objs/ tree the module compiles against,
# and the test binary (installed into /tmp/nginx-test) used for the smoke test.
RUN cd nginx-src && ./configure \
      --prefix=/tmp/nginx-test \
      --with-compat --with-file-aio --with-threads \
      --with-http_addition_module --with-http_auth_request_module --with-http_dav_module \
      --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module \
      --with-http_mp4_module --with-http_random_index_module --with-http_realip_module \
      --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module \
      --with-http_stub_status_module --with-http_sub_module --with-http_v2_module \
      --with-http_v3_module --with-mail --with-mail_ssl_module --with-stream \
      --with-stream_realip_module --with-stream_ssl_module --with-stream_ssl_preread_module \
      --with-cc-opt="${NGINX_CC_OPT}" --with-ld-opt="${NGINX_LD_OPT}" \
 && make -j"$(nproc)" && make install \
 && echo "${NGINX_CC_OPT}" > cc_flags.mk \
 && ALL_INCS=$(awk '/^ALL_INCS/{f=1} f{print} f&&!/\\$/{exit}' objs/Makefile | tr '\\\\' ' ' | sed -e 's/ALL_INCS *=//' -e 's/-I//g') \
 && : > include_paths.mk && for i in $ALL_INCS; do echo "$i" >> include_paths.mk; done \
 && cat include_paths.mk

# The attachment's CMake reads ${CMAKE_INSTALL_PREFIX}/nginx-src/{include_paths,cc_flags}.mk
RUN mkdir -p /build/out && ln -s /build/nginx-src /build/out/nginx-src \
 && cd attachment \
 && cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/build/out \
          -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath,'\$ORIGIN'" . \
 && make -j"$(nproc)" && make install

# Collect module + transitive non-system deps (resolved by DT_NEEDED against the install dir)
RUN mkdir -p /out/lib && cp -L /build/out/lib/libngx_module.so /out/lib/ \
 && changed=1 && while [ $changed = 1 ]; do changed=0; \
      for f in /out/lib/*.so; do \
        for n in $(readelf -d "$f" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do \
          if [ -e "/build/out/lib/$n" ] && [ ! -e "/out/lib/$n" ]; then cp -L "/build/out/lib/$n" /out/lib/; changed=1; fi; \
        done; done; done \
 && for f in /out/lib/*.so; do patchelf --set-rpath '$ORIGIN' "$f"; done \
 && ls -l /out/lib

# Verification 1: RUNPATH + no unresolved libs (run from a neutral dir, no LD_LIBRARY_PATH)
RUN readelf -d /out/lib/libngx_module.so | grep -E 'RPATH|RUNPATH' \
 && ! (ldd /out/lib/libngx_module.so | tee /dev/stderr | grep 'not found') \
 && ! (LD_LIBRARY_PATH=/out/lib ldd /out/lib/libngx_module.so | grep 'not found')

# Verification 2: nginx really dlopen()s the module
RUN printf 'load_module /out/lib/libngx_module.so;\nevents {}\nhttp { server { listen 8080; } }\n' > /tmp/nginx-test/conf/test.conf \
 && /tmp/nginx-test/sbin/nginx -V 2>&1 | head -3 \
 && /tmp/nginx-test/sbin/nginx -t -c /tmp/nginx-test/conf/test.conf

###############################################################################
FROM busybox:stable AS runtime
LABEL org.opencontainers.image.source="https://github.com/k8stooling/openappsec-nginx-attachment" \
      org.opencontainers.image.description="open-appsec NGINX attachment module (initContainer)" \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=builder /out/lib/ /openappsec/lib/
ENTRYPOINT ["/bin/sh", "-c"]
CMD ["cp -fv /openappsec/lib/*.so /opt/openappsec-attachment/"]
