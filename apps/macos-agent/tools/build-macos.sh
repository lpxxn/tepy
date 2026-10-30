#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo 'A native macOS build is required for the CoreGraphics / IOKit bridge.' >&2
    exit 1
fi
export CGO_ENABLED=1
go test -race ./...
go vet ./...
mkdir -p build
go build -trimpath -ldflags '-s -w' -o build/tepy-agent ./cmd/tepy-agent
./build/tepy-agent version
