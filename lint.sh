#!/usr/bin/env bash

set -ex

zig fmt src build.zig --check

pushd src/sphtext/
zig build test
popd

zig build test
zig build

valgrind --suppressions=suppressions.valgrind --leak-check=full --track-fds=yes --error-exitcode=1 ./zig-out/bin/lint
