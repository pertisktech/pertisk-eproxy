.PHONY: all compile shell test clean release docker-release docker-build docker-push docker-eproxy-multi docker-harbor-multi tls-smoke package-deb-amd64 package-rpm-amd64 quic-upstream-local quic-rebuild quic-verify build-openssl11-release-image

REBAR = rebar3
IMAGE ?= harbor.tools.thaidevops.co/pertisksoft/pertisk-eproxy/proxy
VERSION ?= x.x.x
PACKAGE_VERSION := $(patsubst v%,%,$(VERSION))
DOCKERFILE ?= Dockerfile
ERLANG_DOCKER_IMAGE ?= erlang:27
INGRESS_BUILD_PLATFORMS ?= linux/amd64,linux/arm64
INGRESS_BUILD_PROVENANCE ?= false
INGRESS_BUILD_SBOM ?= false
# Set to 1 to enable Cowboy QUIC/HTTP3 hooks when supported by Cowboy build.
COWBOY_QUICER ?= 0
COWBOY_QUIC ?= 0
PACKAGE_NAME ?= pertisk-eproxy
OPENSSL11_RELEASE_BUILD_IMAGE ?= pertisk/otp27-openssl11:local

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

## Rebuild QUIC artifacts only (keeps local _checkouts/quic edits)
quic-rebuild:
	rm -rf _build/default/lib/quic _build/prod/lib/quic
	COWBOY_QUICER=$(COWBOY_QUICER) COWBOY_QUIC=$(COWBOY_QUIC) $(REBAR) compile

## Verify QPACK RIC=0 Chrome compatibility from prod release bits
quic-verify:
	@ERL_BIN=$$(echo _build/prod/rel/pertisk_eproxy/erts-*/bin/erl); \
	if [ ! -e "$$ERL_BIN" ]; then \
		echo "Prod release not found. Run 'make release' first." >&2; \
		exit 1; \
	fi; \
	if [ -x "$$ERL_BIN" ] && "$$ERL_BIN" -version >/dev/null 2>&1; then \
		"$$ERL_BIN" -pa _build/prod/rel/pertisk_eproxy/lib/*/ebin -noshell -eval '\
		case quic_qpack:encode([{<<":status">>, <<"200">>}]) of \
		  <<0,0,_/binary>> -> io:format("qpack_check=ok~n"), init:stop(0); \
		  Encoded -> io:format("qpack_check=bad encoded=~p~n", [Encoded]), init:stop(42) \
		end.'; \
	else \
		echo "quic-verify: local erl is not executable on this host, using Docker ($(ERLANG_DOCKER_IMAGE))."; \
		docker run --rm -v "$$PWD:/src" -w /src $(ERLANG_DOCKER_IMAGE) bash -lc '\
		  ERL_BIN=$$(echo _build/prod/rel/pertisk_eproxy/erts-*/bin/erl); \
		  if [ ! -x "$$ERL_BIN" ]; then echo "Prod release erl binary not runnable in container." >&2; exit 1; fi; \
		  "$$ERL_BIN" -pa _build/prod/rel/pertisk_eproxy/lib/*/ebin -noshell -eval '\''\
		  case quic_qpack:encode([{<<":status">>, <<"200">>}]) of \
		    <<0,0,_/binary>> -> io:format("qpack_check=ok~n"), init:stop(0); \
		    Encoded -> io:format("qpack_check=bad encoded=~p~n", [Encoded]), init:stop(42) \
		  end.'\'''; \
	fi

## Build local OTP27 + OpenSSL1.1 release image for EL8-style RPMs
build-openssl11-release-image:
	docker build -f contrib/docker/otp27-openssl11.Dockerfile -t pertisk/otp27-openssl11:local .

release:
	@ERLANG_DOCKER_IMAGE="$(ERLANG_DOCKER_IMAGE)" bash scripts/build-release-linux.sh

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

package-deb-x86_64: package-deb-amd64

## Build Linux x86_64 RPM package into release/
package-rpm-amd64: ERLANG_DOCKER_IMAGE = almalinux:9
package-rpm-amd64: FORCE_DOCKER_RELEASE = 1
package-rpm-amd64: TARGET_OPENSSL_ABI = 3
package-rpm-amd64: release
	@bash scripts/build-rpm-amd64.sh "$(PACKAGE_NAME)" "$(PACKAGE_VERSION)"

## Build Linux x86_64 RPM with OpenSSL 3 ABI (EL9/bookworm style runtime)
package-rpm-amd64-openssl3:
	@$(MAKE) package-rpm-amd64 ERLANG_DOCKER_IMAGE=almalinux:9 TARGET_OPENSSL_ABI=3

## Build Linux x86_64 RPM with OpenSSL 1.1 ABI (EL8-style runtime)
## Default image is pertisk/otp27-openssl11:local. Build it once via make build-openssl11-release-image.
package-rpm-amd64-openssl11:
	@if ! docker image inspect $(OPENSSL11_RELEASE_BUILD_IMAGE) >/dev/null 2>&1; then \
		echo "OpenSSL1.1 build image not found: $(OPENSSL11_RELEASE_BUILD_IMAGE)" >&2; \
		echo "Run: make build-openssl11-release-image" >&2; \
		exit 1; \
	fi
	@$(MAKE) release ERLANG_DOCKER_IMAGE=$(OPENSSL11_RELEASE_BUILD_IMAGE) FORCE_DOCKER_RELEASE=1 TARGET_OPENSSL_ABI=1.1
	@bash scripts/build-rpm-amd64.sh "$(PACKAGE_NAME)" "$(PACKAGE_VERSION)"

package-rpm-x86_64: package-rpm-amd64

