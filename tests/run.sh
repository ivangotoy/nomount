#!/bin/sh
# NoMount checks: script syntax, data files, nm build with the release flags,
# and the real module scripts run against stubs in a fake module root.
# usage: sh tests/run.sh   (writes only under $TMPDIR; tools that are missing are skipped)
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/nm-tests.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
pass=0 fail=0 skip=0
ok()   { pass=$((pass + 1)); echo "ok   $*"; }
bad()  { fail=$((fail + 1)); echo "FAIL $*"; }
skp()  { skip=$((skip + 1)); echo "skip $*"; }
have() { command -v "$1" >/dev/null 2>&1; }
check() { name=$1; shift; if "$@" > "$W/out" 2>&1; then ok "$name"; else bad "$name"; sed 's/^/     /' "$W/out"; fi; }

# --- shell syntax, by interpreter
find "$R" -name .git -prune -o -type f -name '*.sh' -print | sort > "$W/sh-files"
echo "$R/.forgejo/module-ci.conf" >> "$W/sh-files"
while IFS= read -r f; do
    rel=${f#"$R"/}
    case $f in *.conf) shell=bash ;; *) case $(head -n 1 "$f") in *bash*) shell=bash ;; *) shell=sh ;; esac ;; esac
    if have "$shell"; then check "$shell -n $rel" "$shell" -n "$f"; else skp "$shell -n $rel ($shell missing)"; fi
done < "$W/sh-files"

# --- data files
json_ok() {
    if have python3; then python3 -I -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1"
    else node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1"; fi
}
for f in "$R"/module/webroot/locales/*.json "$R/update.json" "$R/.forgejo/update.json"; do
    if have python3 || have node; then check "json ${f#"$R"/}" json_ok "$f"; else skp "json ${f#"$R"/} (python3/node missing)"; fi
done
for f in "$R"/.forgejo/workflows/*.yml "$R"/.github/workflows/*.yml "$R/module.yaml" "$R/crowdin.yml"; do
    if have python3 && python3 -I -c 'import yaml' 2>/dev/null; then
        check "yaml ${f#"$R"/}" python3 -I -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$f"
    else skp "yaml ${f#"$R"/} (python3 yaml missing)"; fi
done
if have node; then check "node --check module/webroot/index.js" node --check "$R/module/webroot/index.js"
else skp "node --check module/webroot/index.js (node missing)"; fi
if have node; then check "WebUI shell commands quote or number-check every value" node "$R/tests/webui_exec.js" "$R/module/webroot/index.js"
else skp "WebUI shell command check (node missing)"; fi

# --- build() downloads are pinned and hash-checked
C="$R/.forgejo/module-ci.conf"
grep -q 'master' "$C" && bad "module-ci.conf: zig master lookup present" || ok "module-ci.conf: no zig master lookup"
grep -n 'curl ' "$C" | grep -v '^[0-9]*:fetch() ' > "$W/curls"
[ ! -s "$W/curls" ] && ok "module-ci.conf: every download goes through fetch()" || bad "module-ci.conf: curl outside fetch(): $(cat "$W/curls")"
grep '^fetch() ' "$C" | grep -q -- '--connect-timeout [0-9]' && grep '^fetch() ' "$C" | grep -qE -- '--speed-limit [0-9]+ --speed-time [0-9]+' &&
    ok "module-ci.conf: fetch() fails a stalled download" || bad "module-ci.conf: fetch() has no connect/stall bound"
n=$(grep -c '^ *fetch https://' "$C"); h=$(grep -cE '^ *fetch https://[^ ]+ [^ ]+ [0-9a-f]{64}$' "$C")
[ "$n" -ge 3 ] && [ "$n" -eq "$h" ] && ok "module-ci.conf: $n downloads pinned by sha256" || bad "module-ci.conf: $h of $n downloads carry a sha256"
grep -qE 'git -C "\$T/lkmloader" checkout -q [0-9a-f]{40}$' "$C" && ok "module-ci.conf: lkmloader pinned to a commit" || bad "module-ci.conf: lkmloader not pinned"
if have bash && grep -q '^fetch() ' "$C"; then
    mkdir -p "$W/fstub"; printf '#!/bin/sh
while [ "$1" != -o ]; do shift; done; echo payload > "$2"
' > "$W/fstub/curl"; chmod +x "$W/fstub/curl"
    good=$(echo payload | sha256sum | cut -d' ' -f1)
    PATH="$W/fstub:$PATH" bash -c 'set -euo pipefail; eval "$(grep "^fetch() " "$1")"; fetch https://x/f "$2/f1" "$3"; echo reached' sh "$C" "$W" "$good" > "$W/f.out" 2>&1 &&
        grep -q reached "$W/f.out" && ok "fetch(): matching sha256 accepted" || bad "fetch() good hash: $(cat "$W/f.out")"
    PATH="$W/fstub:$PATH" bash -c 'set -euo pipefail; eval "$(grep "^fetch() " "$1")"; fetch https://x/f "$2/f2" 0000000000000000000000000000000000000000000000000000000000000000; echo reached' sh "$C" "$W" > "$W/f.out" 2>&1
    rc=$?; [ "$rc" -ne 0 ] && ! grep -q reached "$W/f.out" && ok "fetch(): sha256 mismatch stops the build" || bad "fetch() bad hash (rc=$rc)"
fi

# --- lkmloader: make names the arm64 build lkmloader-aarch64, customize.sh moves bin/lkmloader-$ARCH_BIN (arm64)
for f in "$R/.github/workflows/build.yml" "$R/.forgejo/module-ci.conf"; do
    if grep -q 'make TARGET=aarch64' "$f"; then
        grep -q 'mv .*lkmloader-aarch64.* .*lkmloader-arm64' "$f" && ok "${f#"$R"/}: arm64 lkmloader renamed for customize.sh" ||
            bad "${f#"$R"/}: lkmloader-aarch64 shipped, customize.sh expects lkmloader-arm64"
    fi
done
grep -q 'mv "$MODPATH/bin/lkmloader-$ARCH_BIN"' "$R/module/customize.sh" && ok "customize.sh takes lkmloader-\$ARCH_BIN" || bad "customize.sh lkmloader name changed"

# --- driver commands: every command nm sends has a case, anything else is -EINVAL
K_SRC="$R/kernel/src/nomount.c"
grep -o 'NM_CMD_[A-Z_]*' "$R/userspace/src/nm.c" "$R/userspace/src/nm.h" | sed 's/.*://' | grep -v '^NM_CMD_UNSPEC$' | sort -u > "$W/sent"
missing=$(while read -r c; do grep -q "case $c:" "$K_SRC" || echo "$c"; done < "$W/sent")
[ -s "$W/sent" ] && [ -z "$missing" ] && ok "driver handles all $(wc -l < "$W/sent") commands nm sends" || bad "driver lacks cases: $missing"
awk '/switch \(payload->cmd\)/,/^    kunmap\(page\);/' "$K_SRC" | grep -A1 'default:' | grep -q 'payload->status = -EINVAL' &&
    ok "driver: unknown command answers -EINVAL" || bad "driver: unknown command reports success"

# --- driver: ADD_RULE/DEL_RULE parse one kernel copy of the request, never the caller's shared page
for c in ADD_RULE DEL_RULE; do
    awk -v c="case NM_CMD_$c:" 'index($0, c) { on = 1 } on { print } on && /^        }$/ { exit }' "$K_SRC" > "$W/case"
    grep -q 'kmemdup(payload->buffer' "$W/case" && ! grep -q 'buf_ptr = payload->buffer' "$W/case" && grep -q 'kfree(req)' "$W/case" &&
        ok "driver: $c parses a kernel copy of the request" || bad "driver: $c parses the shared user page"
done

# --- driver: a stream on its own virtual cursor whose dir lost its virtual children ends there (static check)
awk '/^static int nm_hijacked_iterate_dir\(/,/^}$/' "$K_SRC" | awk '/if \(unlikely\(!orig_fop \|\| !dir_node\)\)/,/nm_iterate_noted/' > "$W/passthru"
grep -q 'nm_rd_is_virtual(nm_rd_get(file, false), ctx->pos, nm_rd_compat())) return 0;' "$W/passthru" &&
    ok "driver: pass-through never hands the stream's virtual cursor to the filesystem" || bad "driver: pass-through hands a virtual cursor to the filesystem"

# --- driver: every pass-through of a stream notes the real positions it hands out, from the first getdents on (static check)
awk '/^static int nm_iterate_noted\(/,/^}$/' "$K_SRC" > "$W/noted"
grep -q 'nm_rd_get(file, true))) return nm_call_iterate(real_file, ctx, fop);' "$W/noted" && grep -q 'nm_rd_note_real(rd, ctx->pos' "$W/noted" &&
    awk '/^static int nm_iterate_view\(/,/^}$/' "$K_SRC" | grep -q 'uid_blocked || !dir_node)) return nm_iterate_noted(file, real_file, ctx, fop);' &&
    awk '/^static int nm_hijacked_iterate_dir\(/,/^}$/' "$K_SRC" | grep -q 'return orig_fop ? nm_iterate_noted(file, file, ctx, orig_fop) : -ENOTDIR;' &&
    ok "driver: pass-through positions are noted, allocation failure falls back to a plain pass-through" || bad "driver: pass-through hands out positions it does not note"

# --- nm with the three zig command lines of build() in .forgejo/module-ci.conf
if have zig; then
    export ZIG_GLOBAL_CACHE_DIR="${TMPDIR:-$W}/nm-zig-cache" ZIG_LOCAL_CACHE_DIR="${TMPDIR:-$W}/nm-zig-cache"
    mkdir -p "$W/bin"
    awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' "$R/.forgejo/module-ci.conf" |
        grep 'zig cc ' | sed -e 's/^[[:space:]]*//' -e 's/) >&2$//' -e "s|-o \.\./\.\./bin/|-o $W/bin/|" > "$W/zig-lines"
    if [ "$(wc -l < "$W/zig-lines")" -eq 3 ]; then ok "build() has 3 zig cc lines"; else bad "build() zig cc lines: $(wc -l < "$W/zig-lines")"; fi
    while IFS= read -r line; do
        out=${line##*-o "$W"/bin/}
        check "zig cc $out" sh -c 'cd "$1" && eval "$2"' sh "$R/userspace/src" "$line"
    done < "$W/zig-lines"
    if [ "$(uname -m)" = x86_64 ] && [ -x "$W/bin/nm-x86_64" ]; then
        "$W/bin/nm-x86_64" > "$W/usage" 2>&1
        if grep -q 'NoMount CLI' "$W/usage"; then ok "nm-x86_64 runs (usage)"; else bad "nm-x86_64 usage"; fi
        # two holders of one lock file: the second gets "busy" (1) while the first holds it, the lock after it is gone
        lk="$W/lockfile"; : > "$lk"
        ( exec 9>>"$lk"; "$W/bin/nm-x86_64" --try-lock <&9 && : > "$W/held"; i=0
          while [ ! -e "$W/release" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done ) & holder=$!
        i=0; while [ ! -e "$W/held" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
        "$W/bin/nm-x86_64" --try-lock < "$lk"; busy=$?
        : > "$W/release"; wait "$holder"
        "$W/bin/nm-x86_64" --try-lock < "$lk"; free=$?
        [ -e "$W/held" ] && [ "$busy" -eq 1 ] && [ "$free" -eq 0 ] && ok "nm --try-lock: second holder busy, lock free after the first exits" ||
            bad "nm --try-lock two holders (held=$([ -e "$W/held" ] && echo y) busy=$busy free=$free)"
    fi
else
    skp "zig cc nm (zig missing)"
fi

# --- module scripts in a fake module root: bin/nm and lkm/lkmloader are stubs, PATH stubs for the rest
M="$W/mod"; D="$W/data"; S="$W/stubs"; L="$W/nm.log"
mkdir -p "$M/bin" "$M/lkm" "$S"
cp "$R"/module/*.sh "$R/module/module.prop" "$M/"
cat > "$M/bin/nm" <<'EOF'
#!/bin/sh
echo "$*" >> "$NM_STUB_LOG"
case $1 in --try-lock) [ -n "${NM_STUB_LOCK_BUSY:-}" ] && exit 1; exit 0 ;; esac
case $1 in version) [ -n "${NM_STUB_NO_DRIVER:-}" ] && [ ! -e "$NM_STUB_LOG.loaded" ] && exit 1; echo 23; exit 0 ;; esac
exit "${NM_STUB_RC:-0}"
EOF
printf '#!/bin/sh\necho "lkmloader $*" >> "$NM_STUB_LOG"\n[ -n "${LKM_RACE:-}" ] && { touch "$NM_STUB_LOG.loaded"; echo "lkmloader: File exists"; }\nexit 1\n' > "$M/lkm/lkmloader"
printf '#!/bin/sh\necho "rmmod $*" >> "$NM_STUB_LOG"\nrm -f "$NM_STUB_LOG.loaded"\n' > "$S/rmmod"
printf '#!/bin/sh\necho "log $*" >> "$NM_STUB_LOG"\n' > "$S/log"
chmod +x "$M/bin/nm" "$M/lkm/lkmloader" "$S"/*
export NM_STUB_LOG="$L" NOMOUNT_DATA="$D" PATH="$S:$PATH"
reset_state() { rm -rf "$D" "$L" "$L.loaded" "$W/modules"; mkdir -p "$D"; : > "$L"; cp "$R/module/module.prop" "$M/module.prop"; unset NM_STUB_NO_DRIVER NM_STUB_RC; }
run_script() { sh "$M/$1" > "$W/script.out" 2>&1; }

reset_state
run_script post-fs-data.sh; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$D/.booting")" = "$(cat /proc/sys/kernel/random/boot_id)" ] && [ ! -e "$D/disable" ] &&
   grep -qx version "$L"; then ok "post-fs-data.sh: driver present, semaphore holds boot_id"
else bad "post-fs-data.sh driver present (rc=$rc)"; cat "$W/script.out" "$L"; fi

reset_state; export NM_STUB_NO_DRIVER=1
run_script post-fs-data.sh; rc=$?
if [ "$rc" -eq 1 ] && [ -e "$D/disable" ] && grep -q 'Kernel not patched' "$M/module.prop" &&
   grep -q "lkmloader $M/lkm/nomount.ko" "$L"; then ok "post-fs-data.sh: no driver disables the module"
else bad "post-fs-data.sh no driver (rc=$rc)"; cat "$W/script.out" "$L"; fi

reset_state; echo other-boot > "$D/.booting"
run_script post-fs-data.sh; rc=$?
if [ "$rc" -eq 1 ] && [ -e "$D/disable" ] && grep -q 'Bootloop Prevented' "$M/module.prop"; then ok "post-fs-data.sh: unfinished previous boot disables the module"
else bad "post-fs-data.sh bootloop (rc=$rc)"; cat "$W/script.out"; fi

reset_state; export NOMOUNT_MODULES_DIR="$W/modules"
for m in nomount alpha beta gamma delta; do mkdir -p "$W/modules/$m"; done
touch "$W/modules/beta/disable" "$W/modules/gamma/skip_mount" "$W/modules/delta/remove"
sed -i 's/^description=.*/description=[old status] x/' "$M/module.prop"
run_script metamount.sh; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep '^module' "$L")" = "module load $W/modules/alpha" ] &&
   grep -q '^description=A metamodule' "$M/module.prop"; then ok "metamount.sh: loads enabled modules only, resets description"
else bad "metamount.sh (rc=$rc)"; cat "$W/script.out" "$L"; fi

reset_state; export NM_STUB_RC=1
for m in alpha beta; do mkdir -p "$W/modules/$m"; done
run_script metamount.sh; rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -c '^module load' "$L")" -eq 2 ]; then ok "metamount.sh: load failure keeps going, exits 1"
else bad "metamount.sh load failure (rc=$rc)"; cat "$W/script.out" "$L"; fi

reset_state; echo some-boot > "$D/.booting"; touch "$D/dump_rules"
run_script boot-completed.sh; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$D/.booting" ] &&
   grep -qx 'rule list' "$L" && grep -q '^log .*rules dump end' "$L"; then ok "boot-completed.sh: clears semaphore, dumps rules when flagged"
else bad "boot-completed.sh (rc=$rc)"; cat "$W/script.out" "$L"; fi

# service.sh re-applies the exclusions in the shape the WebUI writes (compact JSON, uid strings) and the isolated flag
reset_state
printf '%s' '[{"uid":"10123","label":"a \"uid\":\"5\" b","pkg":"p.a"},{"uid":"10456","label":"B","pkg":"p.b"}]' > "$D/.exclusion_list.json"
touch "$D/.block_isolated_uids"
run_script service.sh; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep '^uid' "$L")" = "$(printf 'uid add 10123 10456\nuid block_isolated on')" ]; then ok "service.sh: re-applies excluded UIDs and isolated blocking"
else bad "service.sh (rc=$rc)"; cat "$W/script.out" "$L"; fi
reset_state; echo '[{"uid":"10123"}]' > "$D/.exclusion_list.json"; touch "$D/.block_isolated_uids" "$D/disable"
run_script service.sh; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '^uid' "$L"; then ok "service.sh: disabled module sends nothing"
else bad "service.sh disabled (rc=$rc)"; cat "$W/script.out" "$L"; fi

# file locks (nm --try-lock on fd 9): a free lock is taken, a held one is polled until the timeout
reset_state
MODDIR=$M sh -c '. "$MODDIR/common.sh"; _lock_acquire "$NOMOUNT_DATA/.boot.flock" 5' > "$W/script.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c -- '^--try-lock' "$L")" -eq 1 ] && [ -f "$D/.boot.flock" ]; then ok "_lock_acquire: free lock taken at once"
else bad "_lock_acquire free lock (rc=$rc)"; cat "$W/script.out" "$L"; fi
reset_state
NM_STUB_LOCK_BUSY=1 MODDIR=$M sh -c '. "$MODDIR/common.sh"; _lock_acquire "$NOMOUNT_DATA/.boot.flock" 2' > "$W/script.out" 2>&1; rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -c -- '^--try-lock' "$L")" -eq 2 ]; then ok "_lock_acquire: held lock polled until the timeout"
else bad "_lock_acquire held lock (rc=$rc, $(grep -c -- '^--try-lock' "$L") polls)"; cat "$W/script.out"; fi
# an nm older than --try-lock (customize.sh can install the previous module's nm) answers it with its usage, exit 1:
# boot must neither wait out the lock timeout nor fail
reset_state; cp "$M/bin/nm" "$W/nm.new"
printf '#!/bin/sh\necho "$*" >> "$NM_STUB_LOG"\ncase $1 in --try-lock) echo "NoMount CLI (nm) - Usage Guide:"; exit 1 ;; version) echo 23 ;; esac\nexit 0\n' > "$M/bin/nm"
run_script post-fs-data.sh; rc=$?
cp "$W/nm.new" "$M/bin/nm"
if [ "$rc" -eq 0 ] && [ ! -e "$D/disable" ] && [ "$(grep -c -- '^--try-lock' "$L")" -le 2 ]; then ok "post-fs-data.sh: an nm without --try-lock does not block boot"
else bad "post-fs-data.sh with an nm without --try-lock (rc=$rc, $(grep -c -- '^--try-lock' "$L") polls)"; cat "$W/script.out"; fi
# an install upgraded from the mkdir-lock version keeps its old lock dirs (other names): boot is not affected
reset_state; mkdir "$D/.boot.lock" "$D/.lkm.lock" "$D/.inject.lock"
run_script post-fs-data.sh; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$D/disable" ]; then ok "post-fs-data.sh: leftover mkdir-lock dirs of the previous version do not block boot"
else bad "post-fs-data.sh with leftover lock dirs (rc=$rc)"; cat "$W/script.out"; fi

# --- driver install (customize.sh) and the boot fallback; ksud stub: KSUD_OK=<path part that loads>, KSUD_EXISTS=1
K="$W/ksud-bin"; mkdir -p "$K"
cat > "$K/ksud" <<'EOF2'
#!/bin/sh
case $1 in
    -h) echo "  insmod    Load a kernel module"; exit 0 ;;
    insmod) echo "ksud insmod $2" >> "$NM_STUB_LOG"
        [ -n "${KSUD_RACE:-}" ] && { touch "$NM_STUB_LOG.loaded"; echo "insmod: File exists"; exit 1; }
        if [ -n "${KSUD_OK:-}" ]; then case $2 in *"$KSUD_OK"*) touch "$NM_STUB_LOG.loaded"; exit 0 ;; esac; fi
        [ -n "${KSUD_EXISTS:-}" ] && { echo "insmod: File exists"; exit 1; }
        echo "insmod: Invalid module format"; exit 1 ;;
esac
exit 1
EOF2
printf '#!/bin/sh\n[ "$1" = -r ] && echo 6.6.50-android15-8-g0000000\n' > "$K/uname"
chmod +x "$K/ksud" "$K/uname"
inst() {
    I="$W/inst"; O="$W/old"; rm -rf "$I" "$W/root-bin"; mkdir -p "$I/bin" "$I/lkm"
    cp "$M/bin/nm" "$I/bin/nm-arm64"; cp "$M/lkm/lkmloader" "$I/bin/lkmloader-arm64"
    echo NEW > "$I/lkm/${INST_KO:-nomount-android15-6.6.ko}"
    PATH="$K:$PATH" MODPATH="$I" ARCH=arm64 KSU=true NOMOUNT_OLD_MODPATH="$O" NOMOUNT_PROC_MODULES="$W/proc-modules" \
        NOMOUNT_ROOT_BIN_DIR="$W/root-bin" sh -c 'ui_print() { echo "$*"; }; set_perm() { :; }; abort() { echo "ABORT: $*"; exit 1; }; . "$1"' \
        sh "$R/module/customize.sh" > "$W/inst.out" 2>&1
}
old_module() { rm -rf "$W/old"; mkdir -p "$W/old/bin" "$W/old/lkm"; cp "$M/bin/nm" "$W/old/bin/nm"; echo "$1" > "$W/old/lkm/nomount.ko"; }

reset_state; old_module OLD; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"; export KSUD_EXISTS=1
inst; rc=$?; unset KSUD_EXISTS
if [ "$rc" -eq 0 ] && [ "$(cat "$I/lkm/nomount.ko")" = NEW ] && [ "$(cat "$D/nomount-fallback.ko" 2>/dev/null)" = OLD ] &&
   ! grep -q 'verified' "$W/inst.out"; then ok "customize.sh: running driver, File exists -> new ko staged unproven, running ko kept as fallback"
else bad "customize.sh running driver + File exists (rc=$rc)"; cat "$W/inst.out"; fi

reset_state; old_module OLD; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"
inst; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$I/lkm/nomount.ko")" = OLD ] && [ ! -e "$D/nomount-fallback.ko" ] && [ ! -e "$I/lkm/nomount-android15-6.6.ko" ]; then
    ok "customize.sh: running driver, new ko rejected -> previous ko kept"
else bad "customize.sh running driver + rejected ko (rc=$rc)"; cat "$W/inst.out"; fi

# running driver, new ko rejected: the old ko is kept; the old nm only when the new nm cannot talk to the running driver
old_nm() { printf '#!/bin/sh\n# old nm\necho "old $*" >> "$NM_STUB_LOG"\n[ "$1" = version ] && echo 23\nexit 0\n' > "$W/old/bin/nm"; chmod +x "$W/old/bin/nm"; }
reset_state; old_module OLD; old_nm; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"
inst; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$I/lkm/nomount.ko")" = OLD ] && ! grep -q '# old nm' "$I/bin/nm"; then ok "customize.sh: running driver, new ko rejected, new nm answers -> new nm kept"
else bad "customize.sh rejected ko + new nm answers (rc=$rc)"; cat "$W/inst.out"; fi
reset_state; old_module OLD; old_nm; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"
NM_STUB_NO_DRIVER=1 inst; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$I/lkm/nomount.ko")" = OLD ] && grep -q '# old nm' "$I/bin/nm" && grep -q 'ready for injection' "$W/inst.out"; then
    ok "customize.sh: running driver, new ko rejected, only the old nm answers -> old nm kept"
else bad "customize.sh rejected ko + new nm silent (rc=$rc)"; cat "$W/inst.out"; fi

# when customize.sh puts the previous nm back, the zip's nm stays as bin/nmlock for the boot locks
reset_state; old_module OLD; old_nm; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"
NM_STUB_NO_DRIVER=1 inst; rc=$?
[ "$rc" -eq 0 ] && grep -q '# old nm' "$I/bin/nm" && cmp -s "$I/bin/nmlock" "$M/bin/nm" && ok "customize.sh: old nm put back -> new nm kept as bin/nmlock" ||
    { bad "customize.sh old nm put back, nmlock (rc=$rc)"; cat "$W/inst.out"; }
reset_state; old_module OLD; : > "$W/proc-modules"
printf '#!/bin/sh\n# old nm\ncase $1 in version) [ -e "$NM_STUB_LOG.loaded" ] || exit 1; echo 23 ;; esac\nexit 0\n' > "$W/old/bin/nm"
NM_STUB_NO_DRIVER=1 KSUD_OK=lkm/nomount.ko inst; rc=$?
[ "$rc" -eq 0 ] && grep -q '# old nm' "$I/bin/nm" && cmp -s "$I/bin/nmlock" "$M/bin/nm" && ok "customize.sh: previous driver restored -> new nm kept as bin/nmlock" ||
    { bad "customize.sh previous driver restored, nmlock (rc=$rc)"; cat "$W/inst.out"; }
# bin/nmlock cannot be written: the previous nm must not be put back without it (boot would run unlocked)
mkdir -p "$W/lockfail"
printf '#!/bin/sh\ncase "$2" in */bin/nmlock) printf partial > "$2"; chmod 755 "$2"; echo "cp: write error: No space left on device" >&2; exit 1 ;; esac\nexec /bin/cp "$@"\n' > "$W/lockfail/cp"
chmod +x "$W/lockfail/cp"
for case in rejected restored; do
    reset_state; old_module OLD
    if [ "$case" = rejected ]; then
        old_nm; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"
        PATH="$W/lockfail:$PATH" NM_STUB_NO_DRIVER=1 inst; rc=$?
    else
        : > "$W/proc-modules"
        printf '#!/bin/sh\n# old nm\ncase $1 in version) [ -e "$NM_STUB_LOG.loaded" ] || exit 1; echo 23 ;; esac\nexit 0\n' > "$W/old/bin/nm"
        PATH="$W/lockfail:$PATH" NM_STUB_NO_DRIVER=1 KSUD_OK=lkm/nomount.ko inst; rc=$?
    fi
    if ! grep -q '# old nm' "$I/bin/nm" 2>/dev/null && [ ! -e "$I/bin/nmlock" ]; then ok "customize.sh: $case, bin/nmlock not written -> previous nm not put back, no partial nmlock (rc=$rc)"
    else bad "customize.sh: $case, previous nm put back without bin/nmlock (rc=$rc)"; cat "$W/inst.out"; fi
done
reset_state; old_module OLD; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"; export KSUD_EXISTS=1
inst; rc=$?; unset KSUD_EXISTS
[ "$rc" -eq 0 ] && [ ! -e "$I/bin/nmlock" ] && ok "customize.sh: zip's nm kept -> no bin/nmlock" || { bad "customize.sh nmlock without old nm (rc=$rc)"; cat "$W/inst.out"; }
# boot locks through bin/nmlock when it is there
reset_state; cp "$M/bin/nm" "$W/nm.new"; cp "$M/bin/nm" "$M/bin/nmlock"
printf '#!/bin/sh\necho "$*" >> "$NM_STUB_LOG"\ncase $1 in --try-lock) exit 1 ;; version) echo 23 ;; esac\nexit 0\n' > "$M/bin/nm"
sed -i 's|^echo "\$\*" >> "\$NM_STUB_LOG"$|echo "nmlock $*" >> "$NM_STUB_LOG"|' "$M/bin/nmlock"
run_script post-fs-data.sh; rc=$?
cp "$W/nm.new" "$M/bin/nm"; rm -f "$M/bin/nmlock"
if [ "$rc" -eq 0 ] && grep -q '^nmlock --try-lock' "$L" && ! grep -q '^--try-lock' "$L"; then ok "post-fs-data.sh: locks through bin/nmlock when present"
else bad "post-fs-data.sh nmlock (rc=$rc)"; cat "$W/script.out" "$L"; fi

# running driver and no .ko in the zip for this kernel: the running driver's ko must reach the new module
reset_state; old_module OLD; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"
INST_KO=nomount-android14-6.1.ko inst; rc=$?; unset INST_KO
if [ "$rc" -eq 0 ] && [ "$(cat "$I/lkm/nomount.ko" 2>/dev/null)" = OLD ] && grep -q 'No new KO shipped' "$W/inst.out" &&
   [ ! -e "$I/lkm/nomount-android14-6.1.ko" ]; then ok "customize.sh: running driver, no ko for this kernel -> running ko kept for boot"
else bad "customize.sh running driver + no ko shipped (rc=$rc)"; cat "$W/inst.out"; fi

# running driver, new ko not used: when the running driver's ko cannot be copied into the new module
# (full /data), the install must fail instead of leaving a module without a driver for the next boot
mkdir -p "$W/cpfail"
printf '#!/bin/sh\ncase "$1" in */old/lkm/nomount.ko) echo "cp: write error: No space left on device" >&2; exit 1 ;; esac\nexec /bin/cp "$@"\n' > "$W/cpfail/cp"
chmod +x "$W/cpfail/cp"
for ko in nomount-android14-6.1.ko nomount-android15-6.6.ko; do
    reset_state; old_module OLD; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"
    PATH="$W/cpfail:$PATH" INST_KO=$ko inst; rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'ABORT' "$W/inst.out"; then ok "customize.sh: running driver, $ko, running ko not copied -> install fails"
    else bad "customize.sh running driver, $ko, failed copy of the running ko (rc=$rc)"; cat "$W/inst.out"; fi
done
# the zip's nm or the loaded ko cannot be moved into place: the install fails instead of completing without it
printf '#!/bin/sh\ncase "$1" in $MVFAIL) echo "mv: rename failed: I/O error" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$W/cpfail/mv"
chmod +x "$W/cpfail/mv"
reset_state; old_module OLD; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"
PATH="$W/cpfail:$PATH" MVFAIL='*/bin/nm-arm64' KSUD_EXISTS=1 inst; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'ABORT' "$W/inst.out"; then ok "customize.sh: zip's nm not moved into place -> install fails"
else bad "customize.sh failed mv of the zip's nm (rc=$rc)"; cat "$W/inst.out"; fi
reset_state; old_module OLD; : > "$W/proc-modules"
PATH="$W/cpfail:$PATH" MVFAIL='*/lkm/nomount-android15-6.6.ko' NM_STUB_NO_DRIVER=1 KSUD_OK=nomount-android15-6.6.ko inst; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'ABORT' "$W/inst.out"; then ok "customize.sh: loaded ko not moved into place -> install fails"
else bad "customize.sh failed mv of the loaded ko (rc=$rc)"; cat "$W/inst.out"; fi

reset_state; old_module OLD; : > "$W/proc-modules"; echo stale > "$D/nomount-fallback.ko"
NM_STUB_NO_DRIVER=1 KSUD_OK=nomount-android15-6.6.ko inst; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$I/lkm/nomount.ko")" = NEW ] && [ ! -e "$D/nomount-fallback.ko" ] && grep -q 'ready for injection' "$W/inst.out"; then
    ok "customize.sh: no driver, new ko loads -> installed, stale fallback dropped"
else bad "customize.sh fresh load (rc=$rc)"; cat "$W/inst.out"; fi

reset_state; old_module OLD; : > "$W/proc-modules"
NM_STUB_NO_DRIVER=1 KSUD_EXISTS=1 inst; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'ABORT' "$W/inst.out"; then ok "customize.sh: no working driver, File exists is not taken as loaded"
else bad "customize.sh fresh + File exists (rc=$rc)"; cat "$W/inst.out"; fi

reset_state; old_module OLD; : > "$W/proc-modules"
inst; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$I/lkm" ] && [ ! -e "$D/nomount-fallback.ko" ] && grep -q 'built into the kernel' "$W/inst.out" &&
   ! grep -q insmod "$L"; then ok "customize.sh: built-in driver path unchanged"
else bad "customize.sh built-in (rc=$rc)"; cat "$W/inst.out" "$L"; fi

# boot: new ko fails, fallback loads and becomes the module's ko; normal path never touches the fallback
reset_state; echo NEW > "$M/lkm/nomount.ko"; echo OLD > "$D/nomount-fallback.ko"
NM_STUB_NO_DRIVER=1 KSUD_OK=nomount-fallback.ko PATH="$K:$PATH" sh "$M/post-fs-data.sh" > "$W/script.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$D/disable" ] && grep -q "ksud insmod $D/nomount-fallback.ko" "$L" && [ "$(cat "$M/lkm/nomount.ko")" = OLD ]; then
    ok "post-fs-data.sh: new ko fails -> fallback driver loaded and kept"
else bad "post-fs-data.sh fallback (rc=$rc)"; cat "$W/script.out" "$L"; fi
reset_state; old_module "$(cat "$M/lkm/nomount.ko")"; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"; export KSUD_EXISTS=1
inst; rc=$?; unset KSUD_EXISTS
[ "$rc" -eq 0 ] && [ "$(cat "$D/nomount-fallback.ko" 2>/dev/null)" = OLD ] && ok "customize.sh: install after a fallback boot keeps the working driver as fallback" ||
    { bad "customize.sh install after fallback boot (rc=$rc)"; cat "$W/inst.out"; }
# boot fallback with a full /data: the copy over the module's ko fails half-way; the module's ko must still end
# up as the driver that runs (the installer takes it for the running driver's ko)
mkdir -p "$W/fullstub"
printf '#!/bin/sh\ncase "$2" in $FULL_DEST) : > "$2"; echo "cp: write error: No space left on device" >&2; exit 1 ;; esac\nexec /bin/cp "$@"\n' > "$W/fullstub/cp"
chmod +x "$W/fullstub/cp"
reset_state; echo NEW > "$M/lkm/nomount.ko"; echo OLD > "$D/nomount-fallback.ko"
NM_STUB_NO_DRIVER=1 KSUD_OK=nomount-fallback.ko FULL_DEST='*/lkm/nomount.ko' PATH="$W/fullstub:$K:$PATH" sh "$M/post-fs-data.sh" > "$W/script.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$D/disable" ] && [ "$(cat "$M/lkm/nomount.ko")" = OLD ]; then
    ok "post-fs-data.sh: fallback loaded, copy over the module's ko fails -> module's ko is still the running driver"
else bad "post-fs-data.sh fallback with a failed copy (rc=$rc, module ko: $(cat "$M/lkm/nomount.ko"))"; cat "$W/script.out"; fi
# install after a fallback boot with a full /data: a failed save of the boot fallback keeps the one there
reset_state; old_module OLD; echo OLD > "$D/nomount-fallback.ko"; echo 'nomount 65536 0 - Live 0x0' > "$W/proc-modules"
PATH="$W/fullstub:$PATH" FULL_DEST="$D/*" KSUD_EXISTS=1 inst; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$D/nomount-fallback.ko")" = OLD ] && [ -z "$(ls "$D" | grep -v '^nomount-fallback.ko$')" ]; then
    ok "customize.sh: failed save of the boot fallback keeps the previous fallback, no temp file"
else bad "customize.sh failed fallback save (rc=$rc, fallback: $(cat "$D/nomount-fallback.ko"), data: $(ls "$D" | tr '\n' ' '))"; cat "$W/inst.out"; fi
reset_state; echo NEW > "$M/lkm/nomount.ko"; echo OLD > "$D/nomount-fallback.ko"
NM_STUB_NO_DRIVER=1 KSUD_OK=nomount.ko PATH="$K:$PATH" sh "$M/post-fs-data.sh" > "$W/script.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'nomount-fallback.ko' "$L" && [ "$(cat "$M/lkm/nomount.ko")" = NEW ]; then ok "post-fs-data.sh: new ko loads -> fallback untouched"
else bad "post-fs-data.sh normal path (rc=$rc)"; cat "$W/script.out" "$L"; fi
grep -q '^rm -rf /data/adb/nomount/ ' "$R/module/uninstall.sh" && grep -q 'NOMOUNT_DATA/nomount-fallback.ko' "$R/module/common.sh" &&
    ok "uninstall.sh removes the data dir that holds the fallback ko" || bad "fallback ko not under the uninstalled data dir"
# both boot scripts load at once (no lock): the other one's driver arrives during this load, which then
# answers "File exists"; that driver is kept (no rmmod) and boot goes on
for race in KSUD_RACE LKM_RACE; do
    reset_state; echo NEW > "$M/lkm/nomount.ko"
    if [ "$race" = KSUD_RACE ]; then
        NM_STUB_NO_DRIVER=1 KSUD_RACE=1 PATH="$K:$PATH" sh "$M/post-fs-data.sh" > "$W/script.out" 2>&1; rc=$?
    else
        NM_STUB_NO_DRIVER=1 LKM_RACE=1 sh "$M/post-fs-data.sh" > "$W/script.out" 2>&1; rc=$?
    fi
    if [ "$rc" -eq 0 ] && [ ! -e "$D/disable" ] && ! grep -q '^rmmod' "$L" && [ -e "$L.loaded" ]; then ok "post-fs-data.sh: driver loaded meanwhile ($race) is kept"
    else bad "post-fs-data.sh driver loaded meanwhile, $race (rc=$rc)"; cat "$W/script.out" "$L"; fi
done
rm -f "$M/lkm/nomount.ko"

# bootloop_check runs twice per boot (metamount.sh and post-fs-data.sh); here boot_id is unreadable
# and the wall clock ticks between the calls
printf '#!/bin/sh\nn=$(cat "$NM_DATE_FILE" 2>/dev/null || echo 1000); echo $((n + 1)) > "$NM_DATE_FILE"; echo "$n"\n' > "$S/date"
chmod +x "$S/date"
mkdir -p "$W/catstub"; printf '#!/bin/sh\n[ "$1" = /proc/sys/kernel/random/boot_id ] && exit 1\nexec /bin/cat "$@"\n' > "$W/catstub/cat"; chmod +x "$W/catstub/cat"
no_boot_id_check() { PATH="$W/catstub:$PATH" NM_DATE_FILE="$W/date.n" sh -c 'MODDIR=$1; . "$MODDIR/common.sh"; bootloop_check && bootloop_check' sh "$M" > "$W/script.out" 2>&1; }
reset_state; no_boot_id_check; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$D/disable" ] && grep -q '^btime-' "$D/.booting"; then ok "bootloop_check: two calls in one boot without boot_id"
else bad "bootloop_check without boot_id, same boot (rc=$rc)"; cat "$W/script.out"; fi
reset_state; echo other-boot > "$D/.booting"; no_boot_id_check; rc=$?
if [ "$rc" -eq 1 ] && [ -e "$D/disable" ]; then ok "bootloop_check: unfinished previous boot detected without boot_id"
else bad "bootloop_check without boot_id, previous boot (rc=$rc)"; cat "$W/script.out"; fi
rm -f "$S/date"

# --- metainstall.sh hot install of another module: when the update cannot be moved into place it must stay
# for the next boot (the old module is already deleted). The script's /data/adb paths are hardcoded, so
# this runs a copy with them pointed into $W; busybox is a stub whose mv fails.
MI="$W/mi"; mkdir -p "$MI/adb/modules/x" "$MI/adb/modules_update/x" "$MI/bin"
echo 'id=x old' > "$MI/adb/modules/x/module.prop"; echo 'id=x new' > "$MI/adb/modules_update/x/module.prop"
sed "s|/data/adb/|$MI/adb/|g" "$R/module/metainstall.sh" > "$MI/metainstall.sh"
printf '#!/bin/sh\ncase $1 in mv) echo "mv: rename failed: I/O error" >&2; exit 1 ;; esac\nexec "$@"\n' > "$MI/bin/busybox"; chmod +x "$MI/bin/busybox"
(unset KSU_HAS_HOT_INSTALL; PATH="$MI/bin:$PATH" KSU=true MODID=x MODULE_HOT_INSTALL_REQUEST=true \
    sh -c 'install_module() { :; }; ui_print() { echo "$*"; }; . "$1"' sh "$MI/metainstall.sh") > "$MI/out" 2>&1
if [ "$(cat "$MI/adb/modules_update/x/module.prop" 2>/dev/null)" = 'id=x new' ] && ! grep -q 'No need to reboot' "$MI/out"; then
    ok "metainstall.sh: failed hot install keeps the update for the next boot"
else bad "metainstall.sh failed hot install (update module.prop: $(cat "$MI/adb/modules_update/x/module.prop" 2>&1))"; cat "$MI/out"; fi

# --- kernel/setup.sh on an existing clone (local bare repo as the remote, no network)
if have git && realpath --relative-to=/ / >/dev/null 2>&1; then
    G="$W/setup"; mkdir -p "$G/up/kernel/src" "$G/k/fs"
    gitc() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid git "$@"; }
    up() { echo "$1" > "$G/up/kernel/src/f"; gitc -C "$G/up" add -A && gitc -C "$G/up" commit -qm "$1" && gitc -C "$G/up" push -q "$G/up.git" dev; }
    gitc init -q --bare "$G/up.git"; gitc init -q "$G/up"; gitc -C "$G/up" checkout -q -b dev
    up A; gitc -C "$G/up" tag v1; gitc -C "$G/up" push -q "$G/up.git" v1; a=$(gitc -C "$G/up" rev-parse HEAD)
    gitc clone -q -b dev "$G/up.git" "$G/k/NoMount"
    printf 'obj-y += x/\n' > "$G/k/fs/Makefile"; printf 'menu "x"\nendmenu\n' > "$G/k/fs/Kconfig"
    up B; b=$(gitc -C "$G/up" rev-parse HEAD)
    setup() { (cd "$G/k" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null sh "$R/kernel/setup.sh" "$@") > "$W/setup.out" 2>&1; }
    head_of() { gitc -C "$G/k/NoMount" rev-parse HEAD; }
    setup dev; rc=$?
    [ "$rc" -eq 0 ] && [ "$(head_of)" = "$b" ] && [ -L "$G/k/fs/nomount" ] && ok "setup.sh <branch>: an existing clone moves to the branch head" ||
        { bad "setup.sh <branch> on an existing clone (rc=$rc)"; cat "$W/setup.out"; }
    setup v1; rc=$?
    [ "$rc" -eq 0 ] && [ "$(head_of)" = "$a" ] && ok "setup.sh <tag>: checks out the tag" || { bad "setup.sh <tag> (rc=$rc)"; cat "$W/setup.out"; }
    setup dev >/dev/null; echo local > "$G/k/NoMount/kernel/src/g"; gitc -C "$G/k/NoMount" add -A; gitc -C "$G/k/NoMount" commit -qm local
    c=$(head_of); up D
    setup dev; rc=$?
    [ "$rc" -ne 0 ] && [ "$(head_of)" = "$c" ] && ok "setup.sh <branch>: diverged clone fails, local commit kept" || { bad "setup.sh diverged (rc=$rc)"; cat "$W/setup.out"; }
    # fs/Kconfig cannot be rewritten (awk fails, e.g. a full disk): setup fails and leaves no Kconfig.tmp
    sed -i '/fs\/nomount\/Kconfig/d' "$G/k/fs/Kconfig"; mkdir -p "$G/awkfail"
    printf '#!/bin/sh\necho "awk: write error" >&2\nexit 2\n' > "$G/awkfail/awk"; chmod +x "$G/awkfail/awk"
    PATH="$G/awkfail:$PATH" setup v1; rc=$?
    [ "$rc" -ne 0 ] && [ ! -e "$G/k/fs/Kconfig.tmp" ] && ! grep -q 'Modified fs/Kconfig' "$W/setup.out" && ok "setup.sh: failed fs/Kconfig rewrite fails, no temp file" ||
        { bad "setup.sh failed Kconfig rewrite (rc=$rc, tmp: $([ -e "$G/k/fs/Kconfig.tmp" ] && echo left))"; cat "$W/setup.out"; }
else
    skp "kernel/setup.sh on an existing clone (git or GNU realpath missing)"
fi

# --- nm CLI against a fake driver (tests/nm_fake_driver.c logs every request)
CC=$(command -v cc || command -v gcc || command -v clang || true)
if [ -n "$CC" ] && "$CC" -std=gnu11 -w -Dsyscall=nm_test_syscall -Dmain=nm_main -c "$R/userspace/src/nm.c" -o "$W/nm.o" 2>"$W/cc.out" &&
   "$CC" -std=gnu11 -w "$R/tests/nm_fake_driver.c" "$W/nm.o" -o "$W/nm-fake" 2>>"$W/cc.out"; then
    ok "nm.c builds against the fake driver"
    nm_fake() { : > "$W/drv.log"; NM_FAKE_LOG="$W/drv.log" "$W/nm-fake" "$@" > "$W/nm.out" 2>&1; }
    nm_fake clear; rc=$?
    [ "$rc" -eq 0 ] && [ "$(cat "$W/drv.log")" = "cmd=6 uid=0 arg1=0 size=0" ] && ok "nm clear: clears all" || bad "nm clear (rc=$rc): $(cat "$W/drv.log")"
    nm_fake clear all; rc=$?
    [ "$rc" -eq 0 ] && grep -q '^cmd=6 ' "$W/drv.log" && ok "nm clear all: clears all" || bad "nm clear all (rc=$rc): $(cat "$W/drv.log")"
    nm_fake clear rules; rc=$?
    [ "$rc" -eq 0 ] && grep -q '^cmd=7 ' "$W/drv.log" && ok "nm clear rules: clears rules" || bad "nm clear rules (rc=$rc): $(cat "$W/drv.log")"
    nm_fake clear uid; rc=$?
    [ "$rc" -eq 0 ] && grep -q '^cmd=8 ' "$W/drv.log" && ok "nm clear uid: clears uids" || bad "nm clear uid (rc=$rc): $(cat "$W/drv.log")"
    for word in uids rule everything; do
        nm_fake clear "$word"; rc=$?
        [ "$rc" -eq 1 ] && [ ! -s "$W/drv.log" ] && grep -q 'Usage' "$W/nm.out" && ok "nm clear $word: rejected, nothing sent" ||
            bad "nm clear $word (rc=$rc) sent: $(cat "$W/drv.log")"
    done
    nm_split() { : > "$W/drv.log"; NM_FAKE_LOG="$W/drv.log" "$W/nm-fake" "$@" > "$W/nm.stdout" 2> "$W/nm.stderr"; }
    nm_split rule add --uid abc /a /b; rc=$?
    [ "$rc" -eq 1 ] && [ ! -s "$W/nm.stdout" ] && grep -q 'invalid --uid' "$W/nm.stderr" && ok "nm: argument errors go to stderr" ||
        bad "nm argument error (rc=$rc) stdout: $(cat "$W/nm.stdout") stderr: $(cat "$W/nm.stderr")"
    nm_split rule add "/$(printf '%0300d' 0)" /b; rc=$?
    [ "$rc" -ne 0 ] && [ ! -s "$W/nm.stdout" ] && grep -q 'invalid path' "$W/nm.stderr" && ok "nm: invalid path goes to stderr" ||
        bad "nm invalid path (rc=$rc) stdout: $(cat "$W/nm.stdout")"
    for a in add del; do
        nm_split rule $a; rc=$?
        [ "$rc" -eq 1 ] && [ ! -s "$W/drv.log" ] && [ -s "$W/nm.stderr" ] && ok "nm rule $a without paths: message, exit 1" ||
            bad "nm rule $a without paths (rc=$rc) stderr: $(cat "$W/nm.stderr")"
    done
    nm_split uid block_isolated maybe; rc=$?
    [ "$rc" -eq 1 ] && [ ! -s "$W/drv.log" ] && grep -q 'block_isolated' "$W/nm.stderr" && ok "nm uid block_isolated <bad>: message, exit 1" ||
        bad "nm uid block_isolated bad (rc=$rc) stderr: $(cat "$W/nm.stderr")"
    nm_split uid block_isolated on; rc=$?
    [ "$rc" -eq 0 ] && grep -q '^cmd=11 uid=0 arg1=1 ' "$W/drv.log" && ok "nm uid block_isolated on: sent" || bad "nm uid block_isolated on (rc=$rc)"
    nm_split version; rc=$?
    [ "$rc" -eq 0 ] && [ "$(cat "$W/nm.stdout")" = 23 ] && [ ! -s "$W/nm.stderr" ] && ok "nm version: driver version on stdout" || bad "nm version (rc=$rc)"
else
    if [ -n "$CC" ]; then bad "nm.c fake-driver build"; cat "$W/cc.out"; else skp "nm CLI fake-driver tests (no C compiler)"; fi
fi

# --- driver readdir cursors: kernel/src/nomount_readdir.h in a host model of a hijacked directory stream
if [ -n "$CC" ] && "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror "$R/tests/readdir_model.c" -o "$W/readdir-model" 2>"$W/cc.out"; then
    check "readdir model: every real and virtual entry once, telldir/seekdir, rewind" "$W/readdir-model"
elif [ -n "$CC" ]; then bad "readdir model build"; cat "$W/cc.out"
else skp "readdir model (no C compiler)"; fi

# --- release cleanup (module-ci.sh release): delete only a release the forge still reports as a draft.
# The publish PATCH may be applied by the forge while its reply is lost; deleting on "PUBLISHED != 1"
# alone then removes a published release. Real: log/die/jget/api/cleanup and the publish statements
# (REQ= .. PUBLISHED=1) cut from .forgejo/module-ci.sh; stubbed: curl (fake forge at https://forge.invalid).
CI="$R/.forgejo/module-ci.sh"
if have bash && have python3; then
    mkdir -p "$W/relstub"
    {
        echo 'set -euo pipefail'
        echo 'API=https://forge.invalid/api/v1/repos/example/mod RELEASE_ID=7 PUBLISHED=0 SRC_SHA=0123456789abcdef0123456789abcdef01234567'
        echo 'DRAFT_REQUESTED=0 TAG=v9.9-ci7 REQ={}'
        echo 'AUTH_DIR=$(mktemp -d) AUTH_H=$AUTH_DIR/header; : > "$AUTH_H"'
        sed -n '/^log() {/p; /^die() {/p; /^jget() {/,/^print(d)/p; /^api() {/,/^}/p; /^cleanup() {/,/^}/p' "$CI"
        echo 'trap cleanup EXIT'
        echo 'if [ "$1" = create ]; then RELEASE_ID=""'
        sed -n '/^DRAFT_REQUESTED=1$/,/^RELEASE_ID="\$(api POST \/releases /p' "$CI"
        echo 'elif [ "$1" = publish ]; then'
        sed -n '/^REQ="\$(python3 -I -c .import json,sys;print(json.dumps({"draft":False/,/^PUBLISHED=1$/p' "$CI"
        echo 'else die "upload failed"; fi'
    } > "$W/rel.sh"
    # fake curl: logs "METHOD URL"; POST exits $POST_RC, PATCH $PATCH_RC; GET of the release answers draft=$DRAFT or fails (DRAFT=fail)
    cat > "$W/relstub/curl" <<EOF
#!/bin/sh
m=GET; p=; for a in "\$@"; do [ "\$p" = -X ] && m=\$a; p=\$a; u=\$a; done
echo "\$m \$u" >> "$W/calls"
case "\$m" in
  POST) exit "\${POST_RC:-0}" ;;
  PATCH) exit "\${PATCH_RC:-0}" ;;
  GET) [ "\$DRAFT" = fail ] && exit 22; printf '{"id": 7, "draft": %s}' "\$DRAFT" ;;
esac
EOF
    chmod +x "$W/relstub/curl"
    rel() { mode=$1; shift; : > "$W/calls"; env PATH="$W/relstub:$PATH" TMPDIR="$W" "$@" bash "$W/rel.sh" "$mode" > "$W/rel.err" 2>&1; }
    if ! grep -q '^PUBLISHED=1$' "$W/rel.sh" || ! grep -q '^cleanup() {' "$W/rel.sh" || ! grep -q '^api() {' "$W/rel.sh"; then
        bad "release cleanup: cleanup()/api()/publish statements not found in module-ci.sh"
    else
        rel publish PATCH_RC=28 DRAFT=false; rc=$?
        [ "$rc" -ne 0 ] && grep -q '^PATCH ' "$W/calls" && ! grep -q '^DELETE ' "$W/calls" &&
            ok "release cleanup: failed PATCH, forge reports published: release kept, job fails" ||
            bad "release cleanup: failed PATCH, published (rc=$rc): $(tr '\n' ';' < "$W/calls")"
        rel upload DRAFT=true; rc=$?
        [ "$rc" -ne 0 ] && grep -qx 'DELETE https://forge.invalid/api/v1/repos/example/mod/releases/7' "$W/calls" &&
            ok "release cleanup: failure before publish deletes the draft" ||
            bad "release cleanup: draft not deleted (rc=$rc): $(tr '\n' ';' < "$W/calls")"
        rel publish PATCH_RC=28 DRAFT=fail; rc=$?
        [ "$rc" -ne 0 ] && ! grep -q '^DELETE ' "$W/calls" && grep -q 'release 7' "$W/rel.err" &&
            ok "release cleanup: unreadable state: nothing deleted, release id logged" ||
            bad "release cleanup: unreadable state (rc=$rc): $(tr '\n' ';' < "$W/calls") $(cat "$W/rel.err")"
        rel publish DRAFT=false; rc=$?
        [ "$rc" -eq 0 ] && ! grep -q '^DELETE ' "$W/calls" &&
            ok "release cleanup: good publish deletes nothing, exit 0" ||
            bad "release cleanup: good publish (rc=$rc): $(tr '\n' ';' < "$W/calls")"
        rel create POST_RC=28 DRAFT=true; rc=$?
        [ "$rc" -ne 0 ] && grep -q '^POST ' "$W/calls" && ! grep -q '^DELETE ' "$W/calls" &&
            grep -q 'the draft request for v9.9-ci7 failed or its reply was lost' "$W/rel.err" && ! grep -q 'unbound variable' "$W/rel.err" &&
            ok "release cleanup: failed or unanswered draft request: tag logged for a check by hand" ||
            bad "release cleanup: lost draft reply (rc=$rc): $(tr '\n' ';' < "$W/calls") $(cat "$W/rel.err")"
    fi
else
    skp "release cleanup (bash/python3 missing)"
fi

# build step (module-ci.sh build): whatever the build user started is killed after the build,
# failed or not. setpriv and chown are stubs: the stub records a kill and never runs it (here the
# test user may well be the build uid, and `kill -9 -1` would end this session).
if ! command -v bash >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    skp "module-ci.sh build step (bash/git missing)"
else
    BW="$(mktemp -d "$W/case.XXXXXX")"; mkdir -p "$BW/bin"
    cat > "$BW/bin/setpriv" <<'EOF'
#!/bin/sh
case " $* " in *" kill "*) echo "kill-requested $*" >> "$SETPRIV_LOG"; exit 0 ;; esac
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF
    printf '#!/bin/sh\nexit 0\n' > "$BW/bin/chown"
    chmod 755 "$BW/bin/setpriv" "$BW/bin/chown"
    # build_step <ok|failed>: a work tree with this module-ci.sh and a conf whose build() passes or fails
    build_step() {
        _b="$BW/$1"; mkdir -p "$_b/.forgejo"
        cp "$R/.forgejo/module-ci.sh" "$_b/.forgejo/"
        if [ "$1" = ok ]; then
            printf 'build() { echo zip > "$OUT/module.zip"; }\n' > "$_b/.forgejo/module-ci.conf"
        else
            printf 'build() { echo "stub build failed" >&2; return 1; }\n' > "$_b/.forgejo/module-ci.conf"
        fi
        (cd "$_b" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm t) > /dev/null 2>&1
        : > "$_b/setpriv.log"
        if [ "$(PATH="$BW/bin:$PATH" command -v setpriv)" != "$BW/bin/setpriv" ]; then
            bad "build step $1: setpriv stub not first on PATH, not run"; return
        fi
        _rc=0
        (cd "$_b" && env PATH="$BW/bin:$PATH" SETPRIV_LOG="$_b/setpriv.log" SERVER_URL=https://forge.invalid \
            REPOSITORY=owner/repo BASE_SHA="$(git rev-parse HEAD)" bash .forgejo/module-ci.sh build "$_b") > "$_b/out.log" 2>&1 || _rc=$?
        if [ "$1" = ok ]; then _want=0; [ -f "$_b/.ci-out/module.zip" ] && _res=zip || _res=missing
        else _want=1; grep -q "stub build failed" "$_b/out.log" && _res=stub-failure || _res=missing; fi
        if [ "$([ "$_rc" = 0 ] && echo 0 || echo 1)" = "$_want" ] && [ "$_res" != missing ] \
            && ! grep -q "unbound variable" "$_b/out.log" && grep -q 'kill-requested .*--reuid=1000 .*kill -9 -1' "$_b/setpriv.log"; then
            ok "module-ci.sh build step $1: exit as expected, build user's processes killed"
        else
            bad "module-ci.sh build step $1 (rc=$_rc, $_res, kills: $(grep -c kill-requested "$_b/setpriv.log")): $(tail -n 2 "$_b/out.log" | tr '\n' ' ')"
        fi
    }
    build_step ok
    build_step failed
fi

# --- module-release.yml: the job builds the dispatched commit even when main has moved since. The
# steps whose run text clones or calls `module-ci.sh build` (the merged tree for the kernel modules
# and the build) run against local bare repos: the fork's main has a commit after BASE_SHA, the
# upstream is the dispatched commit itself (nothing to merge). The fixture's .forgejo/module-ci.sh is
# a marker script that records which commit's copy ran; the real pipeline is never reachable from
# here, and git may use the file protocol only. Run blocks are read without PyYAML.
wf_dispatched() {
    _wf=$W/workflow
    mkdir -p "$_wf/job" "$_wf/forge/owner" "$_wf/seed/.forgejo" "$_wf/seed/kernel/src" || return 1
    git init -q --bare "$_wf/forge/owner/repo.git" && git init -q --bare "$_wf/up.git" && git init -q "$_wf/seed" || return 1
    printf 'UPSTREAM_URL=file://%s/up.git\nUPSTREAM_BRANCH=main\n' "$_wf" > "$_wf/seed/.forgejo/module-ci.conf"
    for _c in dispatched later-on-main; do
        printf '#!/bin/sh\necho "%s $*" >> "$MARKER_LOG"\n' "$_c" > "$_wf/seed/.forgejo/module-ci.sh"
        printf '%s\n' "$_c" > "$_wf/seed/kernel/src/version"
        (cd "$_wf/seed" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm "$_c") || return 1
        [ "$_c" = dispatched ] && _base=$(git -C "$_wf/seed" rev-parse HEAD)
    done
    git -C "$_wf/seed" push -q "$_wf/forge/owner/repo.git" HEAD:refs/heads/main || return 1
    git -C "$_wf/seed" push -q "$_wf/up.git" "$_base:refs/heads/main" || return 1
    python3 -I - "$R/.forgejo/workflows/module-release.yml" > "$_wf/steps.sh" <<'PY'
import re, sys
steps, cur = [], None
for l in open(sys.argv[1]).read().split("\n"):
    if re.match(r"^      - name:", l):
        cur = {"run": [], "in": False}; steps.append(cur); continue
    if cur is None:
        continue
    if re.match(r"^        run: \|\s*$", l):
        cur["in"] = True; continue
    m = re.match(r"^        run: (.+)$", l)
    if m:
        cur["run"].append(m.group(1)); continue
    if cur["in"]:
        if l.startswith("          ") or not l.strip():
            cur["run"].append(l[10:])
        else:
            cur["in"] = False
for st in steps:
    text = "\n".join(st["run"])
    if "git clone" in text or "module-ci.sh build" in text:
        print("(\n" + text + "\n)")
PY
    : > "$_wf/marker.log"
    (cd "$_wf/job" && env GIT_ALLOW_PROTOCOL=file SERVER_URL="file://$_wf/forge" REPOSITORY=owner/repo BASE_SHA="$_base" \
        MARKER_LOG="$_wf/marker.log" sh "$_wf/steps.sh") > "$_wf/out.log" 2>&1 || { tail -n 2 "$_wf/out.log"; return 1; }
    [ "$(git -C "$_wf/job/pre" rev-parse HEAD)" = "$_base" ] && [ "$(git -C "$_wf/job/src" rev-parse HEAD)" = "$_base" ] &&
        [ "$(cat "$_wf/job/lkm/tree")" = "$(git -C "$_wf/seed" rev-parse "$_base:kernel/src")" ] &&
        [ "$(cat "$_wf/marker.log")" = "dispatched build src" ] ||
        { echo "pre $(git -C "$_wf/job/pre" log -1 --format=%s 2>&1), src $(git -C "$_wf/job/src" log -1 --format=%s 2>&1), ran: $(tr '\n' ';' < "$_wf/marker.log")"; return 1; }
}
if have python3 && have git; then
    check "module-release.yml: kernel modules, checkout and build use the dispatched commit after main moved" wf_dispatched
else
    skp "module-release.yml dispatched-commit check (python3/git missing)"
fi

echo "summary: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
