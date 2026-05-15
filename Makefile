.PHONY: all build compile run run-web tls-dev-cert shell clean test docs release help admin-install admin-dev admin-build h3-poc-curl h3-poc-erlang-client h3-poc-remote

PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)

all: build test

build:
	@echo "Building pertisk_eproxy..."
	@rebar3 compile
	@echo "(post-hook may patch erlang_quic HTTP/3 deferred invoke + recompile quic once)"

run: build
	@echo "Starting pertisk_eproxy development shell..."
	rebar3 shell

run-web: tls-dev-cert admin-build build

	@if [ "$$(id -u)" -ne 0 ]; then echo "run-web needs root to bind 80/443. Use: sudo make run-web"; exit 1; fi
	@echo "Starting pertisk_eproxy proxy on 80/443/443udp with admin UI on http://localhost:8080 ..."
	rebar3 shell
# 	sudo lsof -nP -iUDP:443 | grep beam.smp | awk '{print $2}' | xargs sudo kill
# Proof-of-concept: QUIC only on the host. Requires another terminal: sudo make run-web.
# In the run-web logs you want: "HTTP/3 QUIC is active". If you see "*** WARNING ... plain gen_udp",
# lsof still shows UDP/443 but curl --http3-only will always time out (fix erlang_quic / certs).
h3-poc-curl:
	@echo "Tip: sudo lsof -nP -iUDP:443 shows sockets; only \"HTTP/3 QUIC is active\" means real QUIC."
	@echo "Snap curl + ngtcp2 sometimes reports ERR_CLOSING even when the server is fine — try: make h3-poc-remote H3_HOST=your.host"
	@echo "Apple curl often uses Secure Transport QUIC; if this hangs, run: make h3-poc-erlang-client"
	@curl -sv --http3-only --connect-timeout 8 \
		--resolve "admin.arm.thaidevops.co:443:127.0.0.1" \
		"https://admin.arm.thaidevops.co/" 2>&1 | sed -n '1,45p'

# Same quic_h3 library as the server. Requires `sudo make run-web` in another tty (loopback). Prefer non-root so _build stays owned by your login user.
h3-poc-erlang-client: build
	@if [ "$$(id -u)" -eq 0 ]; then echo "h3-poc-erlang-client: warning: running as root; _build may become root-owned. Prefer a normal user when possible."; fi
	@escript $(CURDIR)/scripts/h3_local_client.escript

# Full HTTP/3 GET against a live host (UDP 443 must work). Same quic_h3 stack as the server — use this if curl --http3-only shows ERR_CLOSING.
# Example: make h3-poc-remote H3_HOST=admin.arm.thaidevops.co H3_PATH=/api/health
h3-poc-remote: build
	@test -n "$(H3_HOST)" || (echo "Set H3_HOST, e.g. make h3-poc-remote H3_HOST=admin.arm.thaidevops.co"; exit 1)
	@echo "h3-poc-remote: HTTP/3 via erlang_quic (not curl); proves UDP/443 + H3 handler on the target host."
	@if [ -z "$(H3_PATH)" ]; then escript $(CURDIR)/scripts/h3_local_client.escript "$(H3_HOST)"; else escript $(CURDIR)/scripts/h3_local_client.escript "$(H3_HOST)" "$(H3_PATH)"; fi

tls-dev-cert:
	@mkdir -p tls
	@if [ ! -f tls/dev-cert.pem ] || [ ! -f tls/dev-key.pem ]; then \
		echo "Generating development TLS certificate..."; \
		openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 365 \
			-keyout tls/dev-key.pem \
			-out tls/dev-cert.pem \
			-subj "/CN=localhost" \
			-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"; \
	else \
		echo "Using existing development TLS certificate."; \
	fi

# Admin UI targets
admin-install:
	@echo "Installing admin UI dependencies..."
	cd admin-ui && npm install

admin-dev: admin-install
	@echo "Starting admin UI development server..."
	cd admin-ui && npm start

admin-build: admin-install
	@echo "Building admin UI for production..."
	cd admin-ui && npm run build
	sudo rm -rf priv/static
	sudo mkdir -p priv/static
	sudo chown -R $(shell id -un):$(shell id -gn) priv/
	cp -R admin-ui/build/. priv/static/

shell:
	@echo "Starting development shell..."
	rebar3 shell

test:
	@echo "Running tests..."
	rebar3 eunit

test-coverage:
	@echo "Running tests with coverage..."
	rebar3 cover

docs:
	@echo "Generating documentation..."
	rebar3 edoc

release:
	@echo "Building production release..."
	rebar3 as prod release

release-tar:
	@echo "Building release tarball..."
	rebar3 as prod tar

clean:
	@echo "Cleaning build artifacts..."
	rebar3 clean
	rm -rf _build ebin doc

distclean: clean
	@echo "Removing all dependencies..."
	rm -rf deps

dialyzer:
	@echo "Running Dialyzer type checking..."
	rebar3 dialyzer

lint:
	@echo "Running linter..."
	rebar3 lint

fmt:
	@echo "Formatting code..."
	rebar3 fmt

help:
	@echo "Available targets:"
	@echo ""
	@echo "Backend (Erlang):"
	@echo "  make build         - Compile the project"
	@echo "  make run           - Build and start development shell"
	@echo "  make run-web       - Build admin UI and serve reverse proxy on 80/443/443udp"
	@echo "  make h3-poc-curl          - HTTP/3-only curl (needs sudo make run-web; may hang on some curl builds)"
	@echo "  make h3-poc-erlang-client - quic_h3 GET / loopback (needs run-web); non-root preferred for _build ownership"
	@echo "  make h3-poc-remote H3_HOST=host [H3_PATH=/] - quic_h3 GET over the internet (same stack as server; use if curl ERR_CLOSING)"
	@echo "  make shell         - Start development shell"
	@echo "  make test          - Run unit tests"
	@echo "  make test-coverage - Run tests with coverage"
	@echo "  make docs          - Generate documentation"
	@echo "  make release       - Build production release"
	@echo "  make release-tar   - Build release tarball"
	@echo "  make clean         - Clean build artifacts"
	@echo "  make distclean     - Clean everything including deps"
	@echo "  make dialyzer      - Type checking"
	@echo "  make lint          - Run linter"
	@echo "  make fmt           - Format code"
	@echo ""
	@echo "Admin UI (React):"
	@echo "  make admin-install - Install admin UI dependencies"
	@echo "  make admin-dev     - Start admin UI dev server (http://localhost:3000)"
	@echo "  make admin-build   - Build admin UI for production"
