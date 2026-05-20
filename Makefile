.PHONY: all compile shell test clean release docker-release docker-build docker-push docker-eproxy-multi docker-harbor-multi tls-smoke package-deb-amd64 package-rpm-amd64 quic-upstream-local check-vm-args release-openssl11 package-rpm-amd64-openssl11

REBAR = rebar3
IMAGE ?= harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/proxy
VERSION ?= x.x.x
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

admin:
	cd admin && npm ci && npm run build

compile:
	COWBOY_QUICER=$(COWBOY_QUICER) COWBOY_QUIC=$(COWBOY_QUIC) $(REBAR) compile

compile-with-admin: admin compile

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
	@bash scripts/build-release-linux.sh

## Build release with OpenSSL 1.1 ABI (useful for EL8-era hosts)
release-openssl11:
	@RELEASE_BUILD_FORCE_DOCKER=1 RELEASE_BUILD_PLATFORM=linux/amd64 RELEASE_BUILD_IMAGE=erlang:27-bullseye bash scripts/build-release-linux.sh

check-vm-args:
	@erl -noshell -args_file config/vm.args -eval 'halt().' >/dev/null
	@echo "vm.args OK"

docker-release:
	docker build -f $(DOCKERFILE) -t $(IMAGE):$(VERSION) .

docker-build:
	docker buildx build --load -f $(DOCKERFILE) -t $(IMAGE):$(VERSION) .

docker-push:
	docker buildx build --push -f $(DOCKERFILE) -t $(IMAGE):$(VERSION) -t $(IMAGE):latest .

docker-eproxy-multi:
	docker buildx build \
		--platform "$(INGRESS_BUILD_PLATFORMS)" \
		--provenance=$(INGRESS_BUILD_PROVENANCE) \
		--sbom=$(INGRESS_BUILD_SBOM) \
		--push \
		-f $(DOCKERFILE) \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		.

## Multi-arch build + push to Harbor (override VERSION, IMAGE if needed)
docker-harbor-multi: docker-eproxy-multi

## Start the proxy (development — reads config from config/proxy.json)
run: compile-with-admin
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

package-deb-x86_64: package-deb-amd64

## Build Linux x86_64 RPM package into release/
package-rpm-amd64: release
	@bash scripts/build-rpm-amd64.sh "$(PACKAGE_NAME)" "$(PACKAGE_VERSION)"

## Build Linux x86_64 RPM with OpenSSL 1.1-compatible release ABI
package-rpm-amd64-openssl11: release-openssl11
	@TARGET_OPENSSL_ABI=1 bash scripts/build-rpm-amd64.sh "$(PACKAGE_NAME)" "$(PACKAGE_VERSION)"

package-rpm-x86_64: package-rpm-amd64

