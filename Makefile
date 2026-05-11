.PHONY: all compile shell test clean release

REBAR = rebar3

all: compile

compile:
	$(REBAR) compile

shell:
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

## Start the proxy (development — reads config/proxy.json)
run: compile
	$(REBAR) shell --apps pertisk_eproxy

## Hot-reload config without restarting (calls the admin API)
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
