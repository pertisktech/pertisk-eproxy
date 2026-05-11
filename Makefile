.PHONY: all compile shell test clean release docker-release docker-build docker-push docker-eproxy-multi tls-smoke

REBAR = rebar3
IMAGE ?= harbor.example.com/pertisk-eproxy
VERSION ?= v1.0.0
DOCKERFILE ?= Dockerfile
INGRESS_BUILD_PLATFORMS ?= linux/amd64,linux/arm64
INGRESS_BUILD_PROVENANCE ?= false
INGRESS_BUILD_SBOM ?= false

all: compile

compile:
	$(REBAR) compile

shell: compile
	$(REBAR) shell

test:
	$(REBAR) eunit

dialyzer:
	$(REBAR) dialyzer

clean:
	$(REBAR) clean
	rm -rf _build

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
	$(REBAR) shell --apps pertisk_eproxy

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

