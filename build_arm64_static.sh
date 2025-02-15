#!/bin/sh -eu

# Based on https://gist.github.com/j8r/34f1a344336901960c787517b5b6d616

LOCAL_PROJECT_PATH=${1-$PWD}
VERSION=${VERSION-devel}
CMDS="
echo '@edge http://dl-cdn.alpinelinux.org/alpine/edge/community' >>/etc/apk/repositories
apk add --update --no-cache --force-overwrite \
    crystal@edge \
    gc-dev gcc gmp-dev libatomic_ops libevent-static musl-dev pcre-dev \
    libxml2-dev openssl-dev openssl-libs-static tzdata yaml-dev zlib-static \
    make git \
    llvm10-dev llvm10-static g++ \
    shards@edge \
    yaml-static \
    sqlite-dev sqlite-static
cd server
shards install --production
VERSION=${VERSION} time -v shards build --static --release --stats --time
chown 1000:1000 -R bin
mv bin/kadalu-server bin/kadalu-server-arm64
cd ../node
shards install --production
VERSION=${VERSION} time -v shards build --static --release --stats --time
chown 1000:1000 -R bin
mv bin/kadalu-node bin/kadalu-node-arm64
cd ../cli
shards install --production
VERSION=${VERSION} time -v shards build --static --release --stats --time
chown 1000:1000 -R bin
mv bin/kadalu bin/kadalu-arm64
"

# Compile Crystal project statically for arm64 (aarch64)
docker pull multiarch/qemu-user-static:register
docker run --rm --privileged multiarch/qemu-user-static:register --reset
docker run -it -v $LOCAL_PROJECT_PATH:/workspace -w /workspace --rm multiarch/alpine:aarch64-latest-stable /bin/sh -c "$CMDS"
