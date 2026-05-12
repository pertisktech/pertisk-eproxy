.PHONY: all compile shell test clean release docker-release docker-build docker-push docker-eproxy-multi tls-smoke package-deb-amd64 quic-upstream-local

REBAR = rebar3
IMAGE ?= harbor.example.com/pertisk-eproxy
VERSION ?= v1.0.0
PACKAGE_VERSION := $(patsubst v%,%,$(VERSION))
DOCKERFILE ?= Dockerfile
INGRESS_BUILD_PLATFORMS ?= linux/amd64,linux/arm64
INGRESS_BUILD_PROVENANCE ?= false
INGRESS_BUILD_SBOM ?= false
# Set to 1 to enable Cowboy QUIC/HTTP3 hooks when supported by Cowboy build.
COWBOY_QUICER ?= 0
COWBOY_QUIC ?= 0
PACKAGE_NAME ?= pertisk-eproxy

all: compile

compile:
	COWBOY_QUICER=$(COWBOY_QUICER) COWBOY_QUIC=$(COWBOY_QUIC) $(REBAR) compile

shell: compile
	COWBOY_QUICER=$(COWBOY_QUICER) COWBOY_QUIC=$(COWBOY_QUIC) $(REBAR) shell

test:
	$(REBAR) eunit

dialyzer:
	$(REBAR) dialyzer

clean:
	$(REBAR) clean
	rm -rf _build

## Clone benoitc/erlang_quic locally (default: ../erlang_quic), apply interop patch, rebar3 compile — before opening upstream PR
quic-upstream-local:
	bash contrib/erlang_quic_upstream_patches/apply-local.sh

release:
	$(REBAR) as prod release

docker-release: release
	docker build -f $(DOCKERFILE) -t $(IMAGE):$(VERSION) .

docker-build: release
	docker buildx build --load -f $(DOCKERFILE) -t $(IMAGE):$(VERSION) .

docker-push: release
	docker buildx build --push -f $(DOCKERFILE) -t $(IMAGE):$(VERSION) -t $(IMAGE):latest .

docker-eproxy-multi: release
	docker buildx build \
		--platform "$(INGRESS_BUILD_PLATFORMS)" \
		--provenance=$(INGRESS_BUILD_PROVENANCE) \
		--sbom=$(INGRESS_BUILD_SBOM) \
		--push \
		-f $(DOCKERFILE) \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		.

## Start the proxy (development — reads config from config/proxy.json)
run: compile
	COWBOY_QUICER=$(COWBOY_QUICER) COWBOY_QUIC=$(COWBOY_QUIC) $(REBAR) shell --apps pertisk_eproxy

## Hot-reload config from JSON
reload:
	curl -sf -X POST http://127.0.0.1:9080/api/reload | python3 -m json.tool

## Show current config
config:
	curl -sf http://127.0.0.1:9080/api/config | python3 -m json.tool

## Show backend health
health:
	curl -sf http://127.0.0.1:9080/api/health | python3 -m json.tool

## Show Prometheus metrics
metrics:
	curl -sf http://127.0.0.1:9080/api/metrics

## Verify TLS PEM parsing (no running node). Expects priv/tls/listener.pem or pass PEM=path
tls-smoke: compile
	@erlc -o scripts scripts/tls_pem_smoke.erl
	@erl -pa scripts -pa _build/default/lib/pertisk_eproxy/ebin -pa _build/default/lib/*/ebin \
		-noshell -eval "tls_pem_smoke:run(\"$${PEM:-priv/tls/listener.pem}\"), init:stop()."

## Build Linux x86_64 Debian package into release/
package-deb-amd64: release
	@bash scripts/build-deb-amd64.sh "$(PACKAGE_NAME)" "$(PACKAGE_VERSION)"

