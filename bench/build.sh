#!/bin/bash
# In-container: build moonlight-qt at $REF the way scripts/build-appimage.sh does (qmake line verbatim,
# minus linuxdeploy packaging). usage (inside the deps image): build.sh LABEL SHA
set -u
label=$1 sha=$2
cd /work && rm -rf src-$label && git clone -q --filter=blob:none https://github.com/moonlight-stream/moonlight-qt.git src-$label || exit 10
cd src-$label
git fetch -q origin pull/1557/head:pr || true
git checkout -q "$sha" && git submodule update -q --init --recursive || exit 11
for p in ${PATCHES:-}; do git apply "/work/patches/$p" || exit 13; done
export CFLAGS=-flto=auto CXXFLAGS=-flto=auto LDFLAGS=-flto=auto
mkdir -p /work/out-$label build && cd build
t0=$(date +%s)
qmake6 ../moonlight-qt.pro CONFIG+=disable-wayland CONFIG+=disable-libdrm PREFIX=/work/out-$label/usr DEFINES+=APP_IMAGE >/work/out-$label/qmake.log 2>&1 || { echo "qmake_failed"; exit 12; }
make -j"$(nproc)" release >/work/out-$label/make.log 2>&1; rc=$?
t1=$(date +%s)
echo "build_rc=$rc build_s=$((t1-t0)) warnings=$(grep -c 'warning:' /work/out-$label/make.log) errors=$(grep -c 'error:' /work/out-$label/make.log)"
[ $rc = 0 ] && make install >>/work/out-$label/make.log 2>&1
exit $rc
