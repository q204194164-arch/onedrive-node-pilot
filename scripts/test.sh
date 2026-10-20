#!/bin/zsh
set -eu
cd "${0:A:h}/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/onedrive-pilot-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/module-cache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$TEST_DIR/module-cache" Sources/Engine.swift Tests/EngineTests.swift -o "$TEST_DIR/EngineTests" -framework SystemConfiguration -framework Security
"$TEST_DIR/EngineTests"
