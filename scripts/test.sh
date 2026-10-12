#!/bin/sh
# Runs the tests: scripts/test.sh [swift test arguments...]
#
# Plain `swift test` fails now and then with "plugin for module 'TestingMacros' not found":
# Swift Build's explicit-module rebuild loads only the top-level compiler plugins and misses
# plugins/testing/libTestingMacros.dylib. Pointing the compiler at that folder fixes it.
set -e
cd "$(dirname "$0")/.."

developer=$(xcode-select -p)
for dir in "$developer/usr/lib/swift/host/plugins/testing" \
           "$developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"; do
    if [ -d "$dir" ]; then
        exec swift test -Xswiftc -plugin-path -Xswiftc "$dir" "$@"
    fi
done
exec swift test "$@"
