#!/bin/bash

set -e  # exit on a non-zero return code from a command
set -x  # print a trace of commands as they execute

rm -rf .build .symbol-graphs
mkdir -p .symbol-graphs

$(xcrun --find swift) build --target LocalNetworkActorSystem \
    -Xswiftc -emit-symbol-graph \
    -Xswiftc -emit-symbol-graph-dir -Xswiftc .symbol-graphs

rm -f .symbol-graphs/Atomic*
rm -f .symbol-graphs/NIO*
rm -f .symbol-graphs/_NIO*

$(xcrun --find docc) convert Sources/LocalNetworkActorSystem/Documentation.docc \
    --analyze \
    --fallback-display-name LocalNetworkActorSystem \
    --fallback-bundle-identifier com.github.heckj.LocalNetworkActorSystem \
    --fallback-bundle-version 0.1.9 \
    --additional-symbol-graph-dir .symbol-graphs \
    --experimental-documentation-coverage \
    --level brief
