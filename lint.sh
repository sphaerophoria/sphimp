#!/usr/bin/env bash

set -ex

exit 0
zig fmt src build.zig --check

pushd src/sphmath/
zig build test
popd

pushd src/sphtext/
zig build test
popd

pushd src/gui/
zig build test
popd

pushd src/sphutil/
zig build test
popd

pushd src/sphutil_noalloc/
zig build test
popd

pushd src/sphalloc/
zig build test
popd


zig build test
zig build

valgrind --suppressions=suppressions.valgrind --leak-check=full --track-fds=yes --error-exitcode=1 ./zig-out/bin/lint
