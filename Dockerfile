ARG BUILDPLATFORM
ARG TARGETPLATFORM

FROM --platform=$BUILDPLATFORM erlang:27-alpine AS builder

WORKDIR /src

RUN apk add --no-cache bash git build-base cmake ninja perl linux-headers openssl-dev ncurses-dev

COPY . .

RUN rm -rf _build && rebar3 as prod release

FROM alpine:3.20

ARG APP_HOME=/opt/pertisk_eproxy

RUN apk add --no-cache ca-certificates libstdc++ openssl ncurses-libs bash \
    && addgroup -S pertisk \
    && adduser -S -G pertisk pertisk \
    && mkdir -p "${APP_HOME}"

WORKDIR ${APP_HOME}

COPY --chown=pertisk:pertisk --from=builder /src/config ./config
COPY --chown=pertisk:pertisk --from=builder /src/_build/prod/rel/pertisk_eproxy/ ./

USER pertisk

EXPOSE 8080 8443 9080

# Uses management listener (default 127.0.0.1:9080). Override in Compose/K8s if `management_port` differs.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:9080/api/health || exit 1

ENTRYPOINT ["bin/pertisk_eproxy"]
CMD ["foreground"]
