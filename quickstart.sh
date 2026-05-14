#!/bin/bash

# Pertisk eProxy Quick Start Script

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "🚀 Pertisk eProxy Quick Start"
echo "=============================="
echo ""

# Check if Erlang is installed
if ! command -v erl &> /dev/null; then
    echo "❌ Erlang is not installed. Please install Erlang/OTP 25 or later."
    exit 1
fi

echo "✓ Erlang found: $(erl -version 2>&1 | head -1)"

# Check if rebar3 is installed
if ! command -v rebar3 &> /dev/null; then
    echo "❌ rebar3 is not installed. Installing rebar3..."
    mkdir -p ~/.local/bin
    curl https://s3.amazonaws.com/rebar3/rebar3 -o ~/.local/bin/rebar3
    chmod +x ~/.local/bin/rebar3
    export PATH="$PATH:$HOME/.local/bin"
fi

echo "✓ rebar3 found: $(rebar3 --version)"
echo ""

cd "$SCRIPT_DIR"

# Build the project
echo "📦 Building project..."
rebar3 compile
echo "✓ Build complete"
echo ""

# Print next steps
echo "🎯 Next steps:"
echo ""
echo "1. Start development shell:"
echo "   rebar3 shell"
echo ""
echo "2. In the Erlang shell:"
echo "   (pertisk_eproxy@localhost)1> application:start(pertisk_eproxy)."
echo ""
echo "3. Build a release:"
echo "   rebar3 as prod release"
echo ""
echo "4. Run tests:"
echo "   rebar3 eunit"
echo ""
echo "For more information, see README.md"
