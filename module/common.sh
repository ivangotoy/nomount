#!/system/bin/sh
# Shared functions for NoMount's scripts

NOMOUNT_DATA="${NOMOUNT_DATA:-/data/adb/nomount}"
LOADER="$MODDIR/bin/nm"
# customize.sh keeps the zip's nm here when it puts an older nm back (nm before --try-lock)
LOCKER="$MODDIR/bin/nmlock"
[ -x "$LOCKER" ] || LOCKER="$LOADER"
BOOT_SEMAPHORE="$NOMOUNT_DATA/.booting"
DUMP_RULES_FLAG="$NOMOUNT_DATA/dump_rules"
PROP_FILE="$MODDIR/module.prop"
BASE_DESC="A metamodule that replaces OverlayFS/MagicMount with VFS path redirection."

klog()      { echo "<6>nomount: $*" > /dev/kmsg; }
klogwarn()  { echo "<4>nomount: $*" > /dev/kmsg; }
klogerr()   { echo "<3>nomount: $*" > /dev/kmsg; }

try() {
    local out
    out=$("$@" 2>&1) && return 0
    klogerr "$1 failed: $(echo "$out" | head -n 3 | tr '\n' ' ')"
    return 1
}

disable_module() {
    touch "$NOMOUNT_DATA/disable"
    sed -i "s|^description=.*|description=[$1] \\\\n$BASE_DESC|" "$PROP_FILE"
    rm -f "$BOOT_SEMAPHORE"
}

load_ko() {
    local root_cmd=""
    if command -v ksud >/dev/null 2>&1 && ksud -h 2>&1 | grep -qE '(^|[[:space:]])insmod([[:space:]]|$)'; then root_cmd="ksud"
    elif command -v apd >/dev/null 2>&1 && apd -h 2>&1 | grep -qE '(^|[[:space:]])insmod([[:space:]]|$)'; then root_cmd="apd"; fi

    if [ -n "$root_cmd" ]; then
        if try "$root_cmd" insmod "$1" && "$LOADER" version >/dev/null 2>&1; then
            return 0
        fi
        klogwarn "$root_cmd path failed, falling back to lkmloader"
        rmmod nomount 2>/dev/null
    fi

    if ! { try "$MODDIR/lkm/lkmloader" "$1" && "$LOADER" version >/dev/null 2>&1; }; then
        klogerr "lkmloader failed; LKM not loaded"
        return 1
    fi
    return 0
}

_lock_acquire() {
    local n=0 rc out
    command exec 9>>"$1" || return 1
    until out=$("$LOCKER" --try-lock <&9 2>/dev/null); do
        rc=$?
        # an nm without --try-lock answers with its usage: there is no lock to wait for
        case $out in *"NoMount CLI"*) klogwarn "nm has no --try-lock, $1 not locked"; return 0 ;; esac
        if [ "$rc" -ne 1 ] || [ "$((n += 1))" -ge "$2" ]; then
            _lock_release
            return 1
        fi
        sleep 1
    done
}

_lock_release() { exec 9>&-; }

bootloop_check() {
    if ! _lock_acquire "$NOMOUNT_DATA/.boot.flock" 15; then
        klogerr "failed to acquire boot lock"
        return 1
    fi

    local current prev
    current=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    [ -z "$current" ] && current=$(sed -n 's/^btime /btime-/p' /proc/stat 2>/dev/null)
    [ -z "$current" ] && current="fallback-$(date +%s)"

    if [ -f "$BOOT_SEMAPHORE" ] && [ -s "$BOOT_SEMAPHORE" ]; then
        prev=$(cat "$BOOT_SEMAPHORE" 2>/dev/null || echo "MISSING")
        if [ "$prev" != "$current" ]; then
            klogerr "Bootloop detected (prev=$prev current=$current)"
            _lock_release
            disable_module "🚨 Bootloop Prevented"
            return 1
        fi
    else
        klog "NoMount module boot log started"
        echo "$current" > "$BOOT_SEMAPHORE"
    fi

    _lock_release
    return 0
}

ensure_lkm_loaded() {
    if ! _lock_acquire "$NOMOUNT_DATA/.lkm.flock" 60; then
        klogerr "failed to acquire LKM lock"
        return 1
    fi

    if "$LOADER" version >/dev/null 2>&1; then
        _lock_release
        return 0
    fi

    klog "Loading LKM..."
    if ! load_ko "$MODDIR/lkm/nomount.ko"; then
        # kept by customize.sh when the new driver could not be proven at install time
        if [ -f "$NOMOUNT_DATA/nomount-fallback.ko" ] && load_ko "$NOMOUNT_DATA/nomount-fallback.ko"; then
            klogwarn "LKM load failed; loaded the fallback driver and made it the module's driver"
            cp "$NOMOUNT_DATA/nomount-fallback.ko" "$MODDIR/lkm/nomount.ko"
        else
            klogerr "LKM load failed."
            _lock_release
            return 1
        fi
    fi
    klog "LKM loaded and initialized correctly."
    _lock_release
    return 0
}

dump_all_rules_logcat() {
    log -t nomount -p i "rules dump started (triggered $*)"

    "$LOADER" rule list 2>&1 | {
        buf=""
        n=0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            if [ -n "$buf" ] && [ $(( ${#buf} + ${#line} + 3 )) -gt 900 ]; then
                log -t nomount -p i "$buf"
                buf="$line"
            else
                buf="${buf:+$buf ; }$line"
            fi
            n=$((n + 1))
        done
        [ -n "$buf" ] && log -t nomount -p i "$buf"
        log -t nomount -p i "rules dump end (total $n rules)"
    }
}
