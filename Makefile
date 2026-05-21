.PHONY: all compile patch-ekub sync-quic shell test clean release \
	docker-release docker-build docker-push \
	docker-proxy docker-proxy-push docker-proxy-multi \
	docker-ingress docker-ingress-push docker-ingress-multi \
	docker-eproxy-multi docker-harbor-multi \
	tls-smoke package-deb-amd64 package-rpm-amd64 quic-upstream-local \
	run run-ingress reload config health metrics

REBAR = rebar3
HARBOR_REGISTRY ?= harbor.tools.thaidevops.co
HARBOR_PROXY_IMAGE ?= $(HARBOR_REGISTRY)/pertisksoft/pertisk-eproxy/proxy
HARBOR_INGRESS_IMAGE ?= $(HARBOR_REGISTRY)/pertisksoft/pertisk-eproxy/ingress
VERSION ?= x.x.x
PACKAGE_VERSION := $(patsubst v%,%,$(VERSION))
BUILD_PLATFORMS ?= linux/amd64,linux/arm64
BUILD_PROVENANCE ?= false
BUILD_SBOM ?= false
# Set to 1 to enable Cowboy QUIC/HTTP/3 hooks when supported by Cowboy build.
COWBOY_QUICER ?= 0
COWBOY_QUIC ?= 0
PACKAGE_NAME ?= pertisk-eproxy

# Back-compat aliases (default IMAGE = proxy)
IMAGE ?= $(HARBOR_PROXY_IMAGE)
DOCKERFILE ?= Dockerfile
DOCKERFILE_INGRESS ?= Dockerfile.ingress

all: compile

sync-quic:
	@bash scripts/sync-quic-deps.sh

# ekub 0.2.0: fail_if_no_peer_cert is server-only; breaks in-cluster K8s API TLS.
patch-ekub: sync-quic
	@$(REBAR) get-deps
	@bash scripts/patch-ekub.sh

compile: patch-ekub
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

quic-upstream-local:
	bash contrib/erlang_quic_upstream_patches/apply-local.sh

release:
	@bash scripts/build-release-linux.sh

## --- Docker: proxy (admin + SQLite config) ---
docker-proxy: docker-release

docker-proxy-push: docker-push

docker-proxy-multi:
	docker buildx build \
		--platform "$(BUILD_PLATFORMS)" \
		--provenance=$(BUILD_PROVENANCE) \
		--sbom=$(BUILD_SBOM) \
		--push \
		-f $(DOCKERFILE) \
		-t $(HARBOR_PROXY_IMAGE):$(VERSION) \
		-t $(HARBOR_PROXY_IMAGE):latest \
		.

## --- Docker: ingress (K8s controller, read-only admin API) ---
docker-ingress:
	docker build -f $(DOCKERFILE_INGRESS) -t $(HARBOR_INGRESS_IMAGE):$(VERSION) .

docker-ingress-push:
	docker buildx build --load -f $(DOCKERFILE_INGRESS) -t $(HARBOR_INGRESS_IMAGE):$(VERSION) .
	docker push $(HARBOR_INGRESS_IMAGE):$(VERSION)
	docker push $(HARBOR_INGRESS_IMAGE):latest 2>/dev/null || docker tag $(HARBOR_INGRESS_IMAGE):$(VERSION) $(HARBOR_INGRESS_IMAGE):latest && docker push $(HARBOR_INGRESS_IMAGE):latest

docker-ingress-multi:
	docker buildx build \
		--platform "$(BUILD_PLATFORMS)" \
		--provenance=$(BUILD_PROVENANCE) \
		--sbom=$(BUILD_SBOM) \
		--push \
		-f $(DOCKERFILE_INGRESS) \
		-t $(HARBOR_INGRESS_IMAGE):$(VERSION) \
		-t $(HARBOR_INGRESS_IMAGE):latest \
		.

## Back-compat (was single IMAGE; now use docker-ingress-multi for ingress chart)
docker-release:
	docker build -f $(DOCKERFILE) -t $(HARBOR_PROXY_IMAGE):$(VERSION) .

docker-build:
	docker buildx build --load -f $(DOCKERFILE) -t $(HARBOR_PROXY_IMAGE):$(VERSION) .

docker-push:
	docker buildx build --push -f $(DOCKERFILE) \
		-t $(HARBOR_PROXY_IMAGE):$(VERSION) \
		-t $(HARBOR_PROXY_IMAGE):latest \
		.

docker-eproxy-multi: docker-ingress-multi

docker-harbor-multi: docker-proxy-multi docker-ingress-multi

## --- Local run ---
run: compile
	COWBOY_QUICER=$(COWBOY_QUICER) COWBOY_QUIC=$(COWBOY_QUIC) $(REBAR) shell --apps pertisk_eproxy

run-ingress: compile
	PERTISK_MODE=ingress PERTISK_CONFIG_FILE=config/ingress.json \
		COWBOY_QUICER=$(COWBOY_QUICER) COWBOY_QUIC=$(COWBOY_QUIC) $(REBAR) shell --apps pertisk_eproxy

reload:
	curl -sf -X POST http://127.0.0.1:9080/api/reload | python3 -m json.tool

config:
	curl -sf http://127.0.0.1:9080/api/config | python3 -m json.tool

health:
	curl -sf http://127.0.0.1:9080/api/health | python3 -m json.tool

metrics:
	curl -sf http://127.0.0.1:9080/api/metrics

tls-smoke: compile
	@erlc -o scripts scripts/tls_pem_smoke.erl
	@erl -pa scripts -pa _build/default/lib/pertisk_eproxy/ebin -pa _build/default/lib/*/ebin \
		-noshell -eval "tls_pem_smoke:run(\"$${PEM:-priv/tls/listener.pem}\"), init:stop()."

package-deb-amd64: release
	@bash scripts/build-deb-amd64.sh "$(PACKAGE_NAME)" "$(PACKAGE_VERSION)"

package-deb-x86_64: package-deb-amd64

package-rpm-amd64: release
	@bash scripts/build-rpm-amd64.sh "$(PACKAGE_NAME)" "$(PACKAGE_VERSION)"

package-rpm-x86_64: package-rpm-amd64
