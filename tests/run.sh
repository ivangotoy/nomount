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
case $1 in version) [ -n "${NM_STUB_NO_DRIVER:-}" ] && exit 1; echo 23; exit 0 ;; esac
exit "${NM_STUB_RC:-0}"
EOF
printf '#!/bin/sh\necho "lkmloader $*" >> "$NM_STUB_LOG"\nexit 1\n' > "$M/lkm/lkmloader"
printf '#!/bin/sh\nexit 0\n' > "$S/rmmod"
printf '#!/bin/sh\necho "log $*" >> "$NM_STUB_LOG"\n' > "$S/log"
chmod +x "$M/bin/nm" "$M/lkm/lkmloader" "$S"/*
export NM_STUB_LOG="$L" NOMOUNT_DATA="$D" PATH="$S:$PATH"
reset_state() { rm -rf "$D" "$L" "$W/modules"; mkdir -p "$D"; : > "$L"; cp "$R/module/module.prop" "$M/module.prop"; unset NM_STUB_NO_DRIVER NM_STUB_RC; }
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
   grep -q '^description=A metamodule' "$M/module.prop" && [ ! -e "$D/.inject.lock" ]; then ok "metamount.sh: loads enabled modules only, resets description"
else bad "metamount.sh (rc=$rc)"; cat "$W/script.out" "$L"; fi

reset_state; export NM_STUB_RC=1
for m in alpha beta; do mkdir -p "$W/modules/$m"; done
run_script metamount.sh; rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -c '^module load' "$L")" -eq 2 ] && [ ! -e "$D/.inject.lock" ]; then ok "metamount.sh: load failure keeps going, exits 1"
else bad "metamount.sh load failure (rc=$rc)"; cat "$W/script.out" "$L"; fi

reset_state; echo some-boot > "$D/.booting"; mkdir "$D/.boot.lock" "$D/.lkm.lock" "$D/.inject.lock"; touch "$D/dump_rules"
run_script boot-completed.sh; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$D/.booting" ] && [ ! -e "$D/.boot.lock" ] && [ ! -e "$D/.lkm.lock" ] && [ ! -e "$D/.inject.lock" ] &&
   grep -qx 'rule list' "$L" && grep -q '^log .*rules dump end' "$L"; then ok "boot-completed.sh: clears semaphore and locks, dumps rules when flagged"
else bad "boot-completed.sh (rc=$rc)"; cat "$W/script.out" "$L"; fi

# a lock dir that never got its pid and boot_id (holder killed right after mkdir) must not cost the full timeout
reset_state; mkdir "$D/.boot.lock"
MODDIR=$M sh -c '. "$MODDIR/common.sh"; _lock_acquire "$NOMOUNT_DATA/.boot.lock" 5' > "$W/script.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$D/.boot.lock/pid" 2>/dev/null)" != "" ]; then ok "_lock_acquire: lock dir without pid and boot_id is taken over"
else bad "_lock_acquire empty lock dir (rc=$rc)"; cat "$W/script.out"; fi
reset_state; mkdir "$D/.boot.lock"; sleep 600 & held=$!; echo "$held" > "$D/.boot.lock/pid"
MODDIR=$M sh -c '. "$MODDIR/common.sh"; _lock_acquire "$NOMOUNT_DATA/.boot.lock" 3' > "$W/script.out" 2>&1; rc=$?
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null
if [ "$rc" -eq 1 ] && [ "$(cat "$D/.boot.lock/pid")" = "$held" ]; then ok "_lock_acquire: lock held by a live pid is respected"
else bad "_lock_acquire live holder (rc=$rc)"; cat "$W/script.out"; fi

# bootloop_check runs twice per boot (metamount.sh and post-fs-data.sh); here boot_id is unreadable
# and the wall clock ticks between the calls
printf '#!/bin/sh\nn=$(cat "$NM_DATE_FILE" 2>/dev/null || echo 1000); echo $((n + 1)) > "$NM_DATE_FILE"; echo "$n"\n' > "$S/date"
chmod +x "$S/date"
no_boot_id_check() { NM_DATE_FILE="$W/date.n" sh -c 'MODDIR=$1; . "$MODDIR/common.sh"; _nm_boot_id() { :; }; bootloop_check && bootloop_check' sh "$M" > "$W/script.out" 2>&1; }
reset_state; no_boot_id_check; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$D/disable" ] && [ -s "$D/.booting" ]; then ok "bootloop_check: two calls in one boot without boot_id"
else bad "bootloop_check without boot_id, same boot (rc=$rc)"; cat "$W/script.out"; fi
reset_state; echo other-boot > "$D/.booting"; no_boot_id_check; rc=$?
if [ "$rc" -eq 1 ] && [ -e "$D/disable" ]; then ok "bootloop_check: unfinished previous boot detected without boot_id"
else bad "bootloop_check without boot_id, previous boot (rc=$rc)"; cat "$W/script.out"; fi
rm -f "$S/date"

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
else
    if [ -n "$CC" ]; then bad "nm.c fake-driver build"; cat "$W/cc.out"; else skp "nm CLI fake-driver tests (no C compiler)"; fi
fi

echo "summary: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
