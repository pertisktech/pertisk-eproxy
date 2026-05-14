# Development Guide

## Setting Up Development Environment

### Prerequisites

- Erlang/OTP 25+ (https://www.erlang.org/downloads)
- rebar3 (included or https://www.rebar3.org/docs/getting-started)
- macOS, Linux, or similar UNIX environment

### Installation

```bash
# Clone repository
git clone <repository-url>
cd pertisk-eproxy

# Build the project
rebar3 compile

# Start development shell
rebar3 shell
```

## Project Structure

```
pertisk-eproxy/
├── src/                          # Source code
│   ├── pertisk_eproxy_app.erl    # Application startup
│   ├── pertisk_eproxy_sup.erl    # Supervisor
│   ├── pertisk_eproxy_proxy.erl  # QUIC proxy
│   ├── pertisk_eproxy_admin.erl  # Admin API
│   ├── pertisk_eproxy_acme.erl   # ACME client
│   └── pertisk_eproxy_compression.erl  # Compression
├── test/                         # Test files
├── config/                       # Configuration
│   ├── sys.config               # System config
│   └── vm.args                  # VM arguments
├── rebar.config                 # Build config
├── README.md                    # User documentation
└── DEVELOPMENT.md              # This file
```

## Adding a New Module

1. Create a new file in `src/`:
```erlang
%%%-------------------------------------------------------------------
%% @doc My new module description
%% @end
%%%-------------------------------------------------------------------

-module(pertisk_eproxy_mymodule).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}}.

% ... rest of implementation
```

2. Add to supervisor in `src/pertisk_eproxy_sup.erl`:
```erlang
#{
    id => pertisk_eproxy_mymodule,
    start => {pertisk_eproxy_mymodule, start_link, []},
    restart => permanent,
    shutdown => 5000,
    type => worker
}
```

3. Add to `.app.src` file modules list:
```erlang
{modules, [
    ...,
    pertisk_eproxy_mymodule
]}
```

## Integrating erlang_quic

The project uses `erlang_quic` for QUIC protocol support. To integrate it fully:

1. **Initialize QUIC connection**:
```erlang
% In pertisk_eproxy_proxy.erl
Options = [
    {alpn, ["h3"]},
    {max_idle_timeout, 30000},
    {stream_recv_buffer_default, 2097152}
],
quic:listen(Port, Options).
```

2. **Handle streams**:
```erlang
% Stream handler
handle_stream(Stream) ->
    % Receive HTTP request
    receive_request(Stream),
    % Process and route
    route_request(Stream),
    % Send response
    send_response(Stream).
```

3. **Connection callbacks**:
```erlang
handle_quic_error({connection_error, Code}) ->
    io:format("QUIC error: ~p~n", [Code]);
handle_quic_error(timeout) ->
    io:format("Connection timeout~n").
```

## Adding Compression Support

To add compression for a specific format:

1. **Update compression module**:
```erlang
do_compress(myformat, Data) ->
    try
        {ok, myformat:compress(Data, Options)}
    catch
        _:Error -> {error, Error}
    end.
```

2. **Update supported methods**:
```erlang
compression_methods() -> [brotli, zstd, gzip, myformat].
```

3. **Test compression**:
```erlang
rebar3 eunit -m pertisk_eproxy_compression_tests
```

## Adding ACME Providers

To support additional ACME providers:

1. **Create provider module**:
```erlang
-module(pertisk_eproxy_acme_provider_custom).

-export([directory/1, request_order/2, complete_challenge/2]).

directory(Provider) ->
    % Fetch directory from provider
    ok.
```

2. **Register in ACME module**:
```erlang
-define(PROVIDERS, [
    "https://acme-v02.api.letsencrypt.org/directory",
    "https://custom-acme.example.com/directory"
]).
```

## Running Tests

```bash
# Unit tests
rebar3 eunit

# Common test suites
rebar3 ct

# With coverage
rebar3 cover

# Specific test file
rebar3 eunit -m pertisk_eproxy_admin_tests
```

## Code Style

- Use 4-space indentation
- Document public functions with `-spec` and `@doc`
- Use spec types for clarity
- Follow Erlang naming conventions:
  - Modules: lowercase_with_underscores
  - Functions: lowercase_with_underscores
  - Records: #record_name
  - Atoms: lowercase

## Performance Profiling

```erlang
% In development shell
eprof:start().
eprof:profile(pertisk_eproxy_proxy).
eprof:log("profile.txt").
eprof:stop().

% Memory profiling
observer:start().  % GUI profiler

% Parse log
fprof:trace(start, "fprof.trace").
fprof:profile().
fprof:analyse().
fprof:trace(stop).
```

## Debugging

### Enable Debug Logging

```erlang
logger:set_primary_config(level, debug).
logger:set_module_level(pertisk_eproxy_proxy, debug).
```

### Trace Specific Calls

```erlang
% Trace module
trace:trace_calls({pertisk_eproxy_proxy, '_', '_'}).

% Stop tracing
trace:trace_calls(off).

% View trace
trace_dump:print_trace("trace.txt").
```

### Check Process State

```erlang
% Get all processes
erlang:processes().

% Check specific process
sys:get_state(Pid).

% Monitor process
erlang:monitor(process, Pid).
```

## Building Releases

### Development Release

```bash
rebar3 release
./_build/default/rel/pertisk_eproxy/bin/pertisk_eproxy start
```

### Production Release

```bash
rebar3 as prod release
rebar3 as prod tar
# Deploy the tar file
tar -xzf _build/prod/rel/pertisk_eproxy.tar.gz -C /opt/
```

## Troubleshooting

### Compilation Errors

```bash
# Clean and rebuild
rebar3 clean
rebar3 compile

# Check for syntax errors
rebar3 compile -v
```

### Test Failures

```bash
# Run specific test
rebar3 eunit -m module_tests

# Run with debug output
rebar3 eunit -v
```

### Runtime Issues

Check logs:
```bash
tail -f var/log/erlang.log.1
```

Check system:
```erlang
application:which_applications().
supervisor:which_children(pertisk_eproxy_sup).
```

## Contributing

1. Create a feature branch
2. Make changes with tests
3. Run `rebar3 eunit` to verify
4. Submit pull request with description

## Resources

- [Erlang Documentation](https://www.erlang.org/docs)
- [rebar3 Documentation](https://www.rebar3.org/docs)
- [QUIC Protocol](https://www.rfc-editor.org/rfc/rfc9000.html)
- [ACME Protocol](https://tools.ietf.org/html/rfc8555)
- [HTTP/3](https://www.rfc-editor.org/rfc/rfc9114.html)
