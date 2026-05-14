.PHONY: all build compile run run-web tls-dev-cert shell clean test docs release help admin-install admin-dev admin-build

PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)

all: build test

build:
	@echo "Building pertisk_eproxy..."
	rebar3 compile

run: build
	@echo "Starting pertisk_eproxy development shell..."
	rebar3 shell

run-web: tls-dev-cert admin-build build
	@if [ "$$(id -u)" -ne 0 ]; then echo "run-web needs root to bind 80/443. Use: sudo make run-web"; exit 1; fi
	@echo "Starting pertisk_eproxy proxy on 80/443/443udp with admin UI on http://localhost:8080 ..."
	rebar3 shell

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
