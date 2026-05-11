FROM alpine:3.20

RUN apk add --no-cache ca-certificates libstdc++ openssl ncurses-libs bash \
    && addgroup -S pertisk \
    && adduser -S -G pertisk pertisk

WORKDIR /opt/pertisk_eproxy

COPY config ./config
COPY _build/prod/rel/pertisk_eproxy/ ./

RUN chown -R pertisk:pertisk /opt/pertisk_eproxy

USER pertisk

EXPOSE 8080 8443 9080

ENTRYPOINT ["bin/pertisk_eproxy"]
CMD ["foreground"]
