# syntax=docker/dockerfile:1.7
# Proxy + admin image (proxy_admin / proxy modes via config/proxy.json).
# Harbor: harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/proxy

# buildx sets the platform per matrix leg; do not use empty BUILDPLATFORM on FROM
FROM erlang:27-alpine AS builder

WORKDIR /src

RUN apk add --no-cache bash git build-base cmake ninja perl linux-headers openssl-dev ncurses-dev

COPY . .

# ekub 0.2.0 sets fail_if_no_peer_cert (server-only) on K8s API client SSL — patch before compile.
RUN rm -rf _build \
    && rebar3 get-deps \
    && find _build -path '*/ekub/src/ekub_core.erl' -exec sh -c '\
         patch -p1 -d "$$(dirname "$$1")/.." -i /src/contrib/patches/ekub-ssl-client-k8s.patch 2>/dev/null \
           || sed -i "/fail_if_no_peer_cert/d" "$$1"' _ {} \; \
    && rebar3 as prod release

# Runtime must provide OpenSSL >= 3.4 symbols (e.g. EVP_MD_CTX_get_size_ex) for OTP 27 crypto NIF.
# Alpine 3.20 apk openssl is too old; copy libs from erlang:27-alpine builder.
FROM alpine:3.20

ARG APP_HOME=/opt/pertisk_eproxy

RUN apk add --no-cache ca-certificates libstdc++ ncurses-libs bash wget sqlite openssl \
    && addgroup -S pertisk \
    && adduser -S -G pertisk pertisk

WORKDIR ${APP_HOME}

COPY --from=builder /usr/lib/libcrypto.so* /usr/lib/
COPY --from=builder /usr/lib/libssl.so* /usr/lib/
COPY --from=builder /lib/libcrypto.so* /lib/
COPY --from=builder /lib/libssl.so* /lib/

COPY --chown=pertisk:pertisk --from=builder /src/config ./config
COPY --chown=pertisk:pertisk --from=builder /src/_build/prod/rel/pertisk_eproxy/ ./

RUN mkdir -p "${APP_HOME}/log" "${APP_HOME}/data" \
    && chown -R pertisk:pertisk "${APP_HOME}" \
    && chmod 775 "${APP_HOME}/log" "${APP_HOME}/data"

ENV PERTISK_CONFIG_FILE=/opt/pertisk_eproxy/config/proxy.json

USER pertisk

EXPOSE 80 443 9080

# Uses management listener (default 127.0.0.1:9080). Override in Compose/K8s if `management_port` differs.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:9080/api/health || exit 1

ENTRYPOINT ["bin/pertisk_eproxy"]
CMD ["foreground"]
