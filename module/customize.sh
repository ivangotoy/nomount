ui_print " "
ui_print "======================================="
ui_print "               NoMount                 "
ui_print "  Native Kernel Injection Metamodule   "
ui_print "======================================="
ui_print " "

ui_print "- Device Architecture: $ARCH"

# KernelSU reports x86_64 devices as "x64", Magisk as "x86_64"
ARCH_BIN="$ARCH"
[ "$ARCH_BIN" = "x64" ] && ARCH_BIN="x86_64"

# Check root implementation
if [ "$KSU" = "true" ] || command -v ksud >/dev/null 2>&1 || [ -x /data/adb/ksu/bin/ksud ]; then
  ROOT_IMP=ksu
  ui_print "- Root implementation: KernelSU"
elif [ "$APATCH" = "true" ] || command -v apd >/dev/null 2>&1 || [ -x /data/adb/ap/bin/apd ]; then
  ROOT_IMP=ap
  ui_print "- Root implementation: APatch"
else
  abort "! Unsupported root env"
fi

if [ ! -f "$MODPATH/bin/nm-$ARCH_BIN" ]; then
  abort "! Unsupported architecture: $ARCH"
fi
mv "$MODPATH/bin/nm-$ARCH_BIN" "$MODPATH/bin/nm" || abort "! Could not install nm"
set_perm "$MODPATH/bin/nm" 0 0 0755

mv "$MODPATH/bin/lkmloader-$ARCH_BIN" "$MODPATH/lkm/lkmloader" || abort "! Could not install lkmloader"
set_perm "$MODPATH/lkm/lkmloader" 0 0 0755
rm -rf "$MODPATH"/bin/nm-* "$MODPATH"/bin/lkmloader-*

try_load_ko() {
  local output
  local root_cmd=""

  if command -v ksud >/dev/null 2>&1 && ksud -h 2>&1 | grep -qE '(^|[[:space:]])insmod([[:space:]]|$)'; then
    root_cmd="ksud"
  elif command -v apd >/dev/null 2>&1 && apd -h 2>&1 | grep -qE '(^|[[:space:]])insmod([[:space:]]|$)'; then
    root_cmd="apd"
  fi

  if [ -n "$root_cmd" ]; then
    if output=$("$root_cmd" insmod "$1" 2>&1) && "$MODPATH/bin/nm" version >/dev/null 2>&1; then
      return 0
    fi
    if echo "$output" | grep -qi "File exists"; then
      return 3
    fi
    ui_print "  [!] $root_cmd insmod failed: $output"
  fi

  if output=$("$MODPATH/lkm/lkmloader" "$1" 2>&1) && "$MODPATH/bin/nm" version >/dev/null 2>&1; then
    return 0
  fi

  # "File exists": a nomount driver is already loaded, so this one was checked but not loaded
  if echo "$output" | grep -qi "File exists"; then
    return 3
  fi

  ui_print "  [!] lkmloader failed: $output"
  return 1
}

# returns 0 loaded, 3 not loadable while a driver runs (only with $4 = unproven), 2 none shipped, 1 failed
load_ko_for_kernel() {
  local kver="$1" akver="$2" arch_sfx="$3" unproven="$4"
  local exact="$MODPATH/lkm/nomount-${akver}-${kver}${arch_sfx}.ko"
  local mod rc
  local found=0

  if [ -n "$akver" ] && [ -f "$exact" ]; then
    found=1
    ui_print "  [*] Trying: ${exact##*/}"
    try_load_ko "$exact"; rc=$?
    if [ "$rc" = 0 ] || { [ "$rc" = 3 ] && [ -n "$unproven" ]; }; then
      mv "$exact" "$MODPATH/lkm/nomount.ko" || abort "! Could not stage ${exact##*/}"
      return "$rc"
    fi
  fi

  for mod in "$MODPATH"/lkm/nomount*-${kver}${arch_sfx}.ko; do
    [ -f "$mod" ] || continue
    [ "$mod" = "$exact" ] && continue
    found=1
    ui_print "  [*] Trying fallback: ${mod##*/}"
    try_load_ko "$mod"; rc=$?
    if [ "$rc" = 0 ] || { [ "$rc" = 3 ] && [ -n "$unproven" ]; }; then
      mv "$mod" "$MODPATH/lkm/nomount.ko" || abort "! Could not stage ${mod##*/}"
      return "$rc"
    fi
  done

  [ "$found" = 0 ] && return 2
  return 1
}

OLD_MODPATH="${NOMOUNT_OLD_MODPATH:-/data/adb/modules/nomount}"
KVER=$(uname -r | cut -d'.' -f1,2)
AKVER=$(uname -r | grep -oE 'android[0-9]+')
ARCH_SFX=""
[ "$ARCH_BIN" = "x86_64" ] && ARCH_SFX="-x86_64"

if [ -n "$AKVER" ]; then
  ui_print "- Detected Kernel: $KVER ($AKVER branch)"
else
  ui_print "- Detected Kernel: $KVER (Custom/Unknown branch)"
fi

API_RESPONDS=false
LKM_RUNNING=false
BUILTIN=false
STAGED_FOR_REBOOT=false
STAGED_UNPROVEN=false
LOADED_FRESH=false

ui_print "- Checking kernel support via internal API..."
if "$MODPATH/bin/nm" version >/dev/null 2>&1; then
  API_RESPONDS=true
elif [ -x "$OLD_MODPATH/bin/nm" ] && "$OLD_MODPATH/bin/nm" version >/dev/null 2>&1; then
  API_RESPONDS=true
fi

if [ "$API_RESPONDS" = true ]; then
  if grep -q '^nomount ' "${NOMOUNT_PROC_MODULES:-/proc/modules}"; then
    LKM_RUNNING=true
  else
    BUILTIN=true
  fi
fi

if [ "$BUILTIN" = true ]; then
  ui_print "  [OK] NoMount is built into the kernel."
  rm -rf "$MODPATH/lkm"

elif [ "$LKM_RUNNING" = true ]; then
  ui_print "  [*] Active LKM detected."
  ui_print "  [*] Verifying new driver (no unload)..."

  load_ko_for_kernel "$KVER" "$AKVER" "$ARCH_SFX" unproven
  KO_RC=$?

  if [ "$KO_RC" = 0 ]; then
    STAGED_FOR_REBOOT=true
    ui_print "  [+] New driver verified and staged for the next reboot."
  elif [ "$KO_RC" = 3 ]; then
    STAGED_FOR_REBOOT=true
    STAGED_UNPROVEN=true
    ui_print "  [+] New driver passed the loader checks and is staged for the next reboot."
    ui_print "      It cannot be loaded while the current driver runs."
  elif [ "$KO_RC" = 2 ]; then
    ui_print "  [*] No new KO shipped; keeping the running driver as is."
    if [ -f "$OLD_MODPATH/lkm/nomount.ko" ]; then
      mkdir -p "$MODPATH/lkm"
      cp "$OLD_MODPATH/lkm/nomount.ko" "$MODPATH/lkm/nomount.ko" || abort "! Could not keep the running driver's KO"
    fi
  else
    ui_print "  [!] New driver failed verification; keeping the running one."
    if [ -f "$OLD_MODPATH/lkm/nomount.ko" ]; then
      mkdir -p "$MODPATH/lkm"
      cp "$OLD_MODPATH/lkm/nomount.ko" "$MODPATH/lkm/nomount.ko" || abort "! Could not keep the running driver's KO"
      # the old nm only when the new one cannot talk to the running driver
      if ! "$MODPATH/bin/nm" version >/dev/null 2>&1; then
        cp "$MODPATH/bin/nm" "$MODPATH/bin/nmlock" && set_perm "$MODPATH/bin/nmlock" 0 0 0755
        cp "$OLD_MODPATH/bin/nm" "$MODPATH/bin/nm" 2>/dev/null && set_perm "$MODPATH/bin/nm" 0 0 0755
      fi
    fi
  fi

  rm -f "$MODPATH"/lkm/nomount-*.ko

else
  ui_print "  [*] Built-in support not found. Attempting LKM injection..."

  if load_ko_for_kernel "$KVER" "$AKVER" "$ARCH_SFX"; then
    LOADED_FRESH=true
  fi

  if [ "$LOADED_FRESH" = false ] && [ -f "$OLD_MODPATH/lkm/nomount.ko" ]; then
    ui_print "  [!] New driver failed; restoring previous working LKM..."
    mkdir -p "$MODPATH/lkm"
    cp "$OLD_MODPATH/lkm/nomount.ko" "$MODPATH/lkm/nomount.ko"
    cp "$MODPATH/bin/nm" "$MODPATH/bin/nmlock" && set_perm "$MODPATH/bin/nmlock" 0 0 0755
    cp "$OLD_MODPATH/bin/nm" "$MODPATH/bin/nm" 2>/dev/null && set_perm "$MODPATH/bin/nm" 0 0 0755
    if try_load_ko "$MODPATH/lkm/nomount.ko"; then
      LOADED_FRESH=true
    fi
  fi

  rm -f "$MODPATH"/lkm/nomount-*.ko

  if [ "$LOADED_FRESH" = false ]; then
    ui_print " "
    ui_print "***************************************************"
    ui_print "* [!] WARNING: KERNEL DRIVER NOT DETECTED         *"
    ui_print "***************************************************"
    ui_print "* NoMount Internal API missing/unresponsive and   *"
    ui_print "* no compatible loadable kernel module was found. *"
    ui_print "*                                                 *"
    ui_print "* This module will NOT FUNCTION until you flash   *"
    ui_print "* a Kernel compiled with CONFIG_NOMOUNT=y         *"
    ui_print "***************************************************"
    ui_print " "
    abort "! Kernel module not detected"
  fi
fi

NM_REQUIRED_VER=22
NM_CURRENT_VER=$("$MODPATH/bin/nm" version 2>/dev/null | head -1 | grep -oE '^[0-9]+' | head -1)
NM_CURRENT_VER=${NM_CURRENT_VER:-0}

if [ "$NM_CURRENT_VER" -lt "$NM_REQUIRED_VER" ]; then
  if [ "$BUILTIN" = true ]; then
    ui_print " "
    ui_print "***************************************************"
    ui_print "* [!] BUILT-IN DRIVER TOO OLD                     *"
    ui_print "***************************************************"
    ui_print "* Built-in driver: v${NM_CURRENT_VER}             *"
    ui_print "* Required:        v${NM_REQUIRED_VER}            *"
    ui_print "*                                                 *"
    ui_print "* This kernel has an older NoMount built into it. *"
    ui_print "* Flash a kernel with v${NM_REQUIRED_VER}+, or    *"
    ui_print "* downgrade to NoMount v2.1.x.                    *"
    ui_print "***************************************************"
    ui_print " "
    abort "! Built-in driver v${NM_CURRENT_VER} incompatible (v${NM_REQUIRED_VER} required)"
  elif [ "$STAGED_FOR_REBOOT" = true ]; then
    ui_print "  [!] Current driver: v${NM_CURRENT_VER}; this module requires v${NM_REQUIRED_VER}+"
    ui_print "  [!] A v${NM_REQUIRED_VER} driver is staged for the next boot."
    ui_print "  [!] Do NOT use 'nm rule' or 'nm uid' until you reboot:"
    ui_print "      the v${NM_REQUIRED_VER} CLI cannot talk to the v${NM_CURRENT_VER} driver."
  else
    ui_print " "
    ui_print "***************************************************"
    ui_print "* [!] KERNEL DRIVER TOO OLD                       *"
    ui_print "***************************************************"
    ui_print "* Current driver: v${NM_CURRENT_VER}              *"
    ui_print "* Required:       v${NM_REQUIRED_VER} as minimum  *"
    ui_print "*                                                 *"
    ui_print "* No compatible driver update is available for    *"
    ui_print "* this kernel. Update your kernel first, then     *"
    ui_print "* reinstall this module. If you cannot update    *"
    ui_print "* the kernel, downgrade to NoMount v2.1.x.        *"
    ui_print "***************************************************"
    ui_print " "
    abort "! Kernel driver v${NM_CURRENT_VER} incompatible (v${NM_REQUIRED_VER} required)"
  fi
fi

if [ "$STAGED_FOR_REBOOT" = true ]; then
  ui_print "  [OK] Update staged. Reboot to activate the new driver."
  if [ "$NM_CURRENT_VER" -ge "$NM_REQUIRED_VER" ]; then
    ui_print "       The current driver keeps working until then."
  fi
else
  ui_print "  [OK] System is ready for injection."
fi

NOMOUNT_DATA="${NOMOUNT_DATA:-/data/adb/nomount}"
mkdir -p "$NOMOUNT_DATA"
rm -f "$NOMOUNT_DATA/.booting"

# the staged driver is unproven: keep the running one where boot can load it if the new one fails
if [ "$STAGED_UNPROVEN" = true ] && [ "$NM_CURRENT_VER" -ge "$NM_REQUIRED_VER" ] && [ -f "$OLD_MODPATH/lkm/nomount.ko" ]; then
  # through a temp file: a failed copy (full /data) leaves the fallback that is there
  if cp "$OLD_MODPATH/lkm/nomount.ko" "$NOMOUNT_DATA/nomount-fallback.ko.tmp" &&
     mv -f "$NOMOUNT_DATA/nomount-fallback.ko.tmp" "$NOMOUNT_DATA/nomount-fallback.ko"; then
    ui_print "  [*] Current driver kept as boot fallback."
  else
    rm -f "$NOMOUNT_DATA/nomount-fallback.ko.tmp"
  fi
elif [ "$BUILTIN" != true ]; then
  rm -f "$NOMOUNT_DATA/nomount-fallback.ko"
fi

ROOT_BIN_DIR="${NOMOUNT_ROOT_BIN_DIR:-/data/adb/$ROOT_IMP/bin}"
mkdir -p "$ROOT_BIN_DIR"
if ln -sf "/data/adb/modules/nomount/bin/nm" "$ROOT_BIN_DIR/nm"; then
  ui_print "- Symlink created."
else
  ui_print "! Failed to create 'nm' symlink, skipping.."
fi

ui_print "- Installation complete."
