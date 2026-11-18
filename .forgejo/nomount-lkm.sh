#!/usr/bin/env bash
# Builds nomount.ko for one KMI, arm64 and x86_64, inside ghcr.io/ylarod/ddk-min:<kmi>
# (steps of upstream .github/workflows/build-lkm.yml).
#   nomount-lkm.sh <kmi> <kernel/src of the merged tree> <out dir>
set -euo pipefail
kmi=$1 src=$(cd "$2" && pwd) out=$3
mkdir -p "$out"; out=$(cd "$out" && pwd)
[ -n "${KDIR:-}" ] && [ -f "$KDIR/Makefile" ] || { echo "KDIR not available: ${KDIR:-<empty>}" >&2; exit 1; }
command -v llvm-strip >/dev/null || { echo "llvm-strip not available" >&2; exit 1; }

# x86_64 kdir, as upstream
KDIR_X64="/opt/ddk/kdir-x64/$kmi"
(
    unset ARCH CROSS_COMPILE
    mkdir -p "$KDIR_X64"
    cd "/opt/ddk/src/$kmi"
    MODPOST=scripts/mod/modpost.c
    sed -i -E 's/^([[:space:]]*)check_exports\(mod\);/\1\/\/ check_exports(mod);/' "$MODPOST"
    sed -i -E 's/^([[:space:]]*)s->module = exp->module;/\1\/\/ s->module = exp->module;/' "$MODPOST"
    sed -i 's/^static void check_exports(/static void __attribute__((unused)) check_exports(/' "$MODPOST"
    sed -i 's/__version_ext_names\\") =\\n/__version_ext_names\\") = \\"\\"\\n/' "$MODPOST"
    make ARCH=x86_64 O="$KDIR_X64" LLVM=1 LLVM_IAS=1 -j"$(nproc)" x86_64_defconfig
    scripts/config --file "$KDIR_X64/.config" -d LTO_CLANG -e LTO_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL -d THINLTO
    make ARCH=x86_64 O="$KDIR_X64" LLVM=1 LLVM_IAS=1 -j"$(nproc)" modules_prepare
) >&2

# strip page pinner symbols, as upstream
for MM in /opt/ddk/src/*/include/linux/mm.h /opt/ddk/kdir/*/include/linux/mm.h /opt/ddk/kdir-x64/*/include/linux/mm.h; do
    [ -f "$MM" ] || continue
    if grep -q '^#include <linux/page_pinner.h>' "$MM"; then
        sed -i 's|^#include <linux/page_pinner.h>|/* NoMount CI: page_pinner disabled */|' "$MM"
        sed -i 's|^\tpage_pinner_put_page(page);|\t/* NoMount CI: page_pinner disabled */|' "$MM"
    fi
done

for arch in arm64 x86_64; do
    w="$out/build-$kmi-$arch"
    rm -rf "$w"; cp -r "$src" "$w"
    if [ "$arch" = x86_64 ]; then
        (unset ARCH CROSS_COMPILE; CONFIG_NOMOUNT=m make -j"$(nproc)" -C "$KDIR_X64" ARCH=x86_64 LLVM=1 LLVM_IAS=1 M="$w" modules) >&2
        name="nomount-$kmi-x86_64.ko"
    else
        CONFIG_NOMOUNT=m make -j"$(nproc)" -C "$KDIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 M="$w" modules >&2
        name="nomount-$kmi.ko"
    fi
    install -Dm644 "$w/nomount.ko" "$out/$name"
    llvm-strip --strip-unneeded -R .BTF "$out/$name"
    rm -rf "$w"
    ls -l "$out/$name"
done
chmod -R a+rX "$out"
