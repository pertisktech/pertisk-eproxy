# Adding erlang_quic Support

The project is currently set up to run without erlang_quic to allow development without the native library. To enable full QUIC/HTTP3 support, follow these steps:

## Prerequisites

erlang_quic requires a C compiler and some system libraries:

**macOS:**
```bash
# Install build tools
xcode-select --install

# Install dependencies via Homebrew
brew install openssl@1.1
```

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install build-essential libssl-dev erlang-dev
```

## Installation

1. **Add erlang_quic to rebar.config:**

Edit `rebar.config` and add to deps:
```erlang
{deps, [
    % ... other deps ...
    {erlang_quic, {git, "https://github.com/benoitc/erlang_quic.git", {branch, "main"}}}
]}.
```

2. **Add to release and application:**

Edit `rebar.config` relx section - add to release apps list:
```erlang
{release, {pertisk_eproxy, "0.1.0"}, [
    % ... other apps ...
    erlang_quic
]},
```

Edit `src/pertisk_eproxy.app.src` - add to applications:
```erlang
{applications, [
    % ... other apps ...
    erlang_quic
]},
```

3. **Compile:**

```bash
# Clean previous build
rebar3 clean

# Compile with erlang_quic
rebar3 compile

# If compilation fails, check that:
# - OpenSSL development files are installed
# - C compiler is available (gcc/clang)
# - Erlang development headers are available
```

## Testing QUIC Connection

Once compiled, test the QUIC listener:

```erlang
% In rebar3 shell
(pertisk_eproxy@localhost)1> application:start(pertisk_eproxy).

% Check that QUIC listener started on port 443
(pertisk_eproxy@localhost)2> erlang:processes().
```

## Alternative: Using h2 for HTTP/2

If you don't need HTTP/3 support yet, you can use the `h2` library for HTTP/2:

```erlang
{deps, [
    {h2, "2.0.0"},
    % ...
]}
```

This provides HTTP/2 support without native library compilation.

## Troubleshooting

### "erlang_quic.app not found"

This happens when erlang_quic isn't in the deps. Make sure:
1. It's added to rebar.config deps
2. You ran `rebar3 get-deps` or `rebar3 compile`
3. No build cache issues: try `rebar3 clean && rebar3 compile`

### OpenSSL errors during compilation

Specify OpenSSL location:
```bash
LDFLAGS="-L/usr/local/opt/openssl@1.1/lib" \
CFLAGS="-I/usr/local/opt/openssl@1.1/include" \
rebar3 compile
```

### Linking errors

Try updating rebar3 and cleaning:
```bash
rebar3 do clean, update, compile
```

## Resources

- [erlang_quic GitHub](https://github.com/benoitc/erlang_quic)
- [QUIC RFC 9000](https://www.rfc-editor.org/rfc/rfc9000.html)
- [HTTP/3 RFC 9114](https://www.rfc-editor.org/rfc/rfc9114.html)
