#!/bin/bash
# =============================================================================
# Created with Claude AI
# =============================================================================
# make-appimage.sh
# Builds a portable AppImage of key-mon on Ubuntu 20.04 LTS (x86_64)
#
# Prerequisites:
#   sudo apt-get install -y \
#       python3-pip python3-gi python3-gi-cairo python3-xlib \
#       gir1.2-gtk-3.0 librsvg2-common git wget
# =============================================================================
set -eu

# ─── Configuration ────────────────────────────────────────────────────────────
APP_NAME="Key-Mon"
REPO_URL="https://github.com/setaur/key-mon"
ARCH=$(uname -m)

WORK_DIR="$(mktemp -d /tmp/keymon-build-XXXXXX)"
APPDIR="$WORK_DIR/$APP_NAME.AppDir"

PYTHON=$(which python3)
PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_TAG="python${PY_VER}"

# gdk-pixbuf loader directory (Ubuntu 20.04 default)
GDK_PB_VER="2.10.0"
GDK_PB_SYSDIR="/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/$GDK_PB_VER"

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "\e[32m==>\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

# Copies a shared library (.so) by name into $APPDIR/usr/lib/
copy_so() {
    local lib="$1"
    local found
    found=$(find /usr/lib/x86_64-linux-gnu /usr/lib /lib/x86_64-linux-gnu \
            -maxdepth 3 -name "$lib" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        cp -Lf "$found" "$APPDIR/usr/lib/" 2>/dev/null \
            && log "  .so: $lib" || true
    else
        warn "  Not found: $lib"
    fi
}

# ─── Prerequisite check ───────────────────────────────────────────────────────
log "=== Checking prerequisites ==="

for cmd in python3 pip3 git wget; do
    command -v "$cmd" >/dev/null 2>&1 \
        || err "Missing command: $cmd"
done

python3 -c "import gi"   2>/dev/null \
    || err "Missing Python package: gi   — sudo apt-get install python3-gi python3-gi-cairo"
python3 -c "import Xlib" 2>/dev/null \
    || err "Missing Python package: Xlib — sudo apt-get install python3-xlib"

# gdk-pixbuf-query-loaders is not in $PATH on Ubuntu (package: libgdk-pixbuf2.0-bin).
# Try PATH first, then search known locations.
GDK_QB_BIN=$(command -v gdk-pixbuf-query-loaders 2>/dev/null \
    || find /usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0 /usr/lib/gdk-pixbuf-2.0 \
       -name "gdk-pixbuf-query-loaders" 2>/dev/null \
    || true)
GDK_QB_BIN=$(echo "$GDK_QB_BIN" | head -1)
[ -n "$GDK_QB_BIN" ] \
    || err "gdk-pixbuf-query-loaders not found"
log "  gdk-pixbuf-query-loaders: $GDK_QB_BIN"

[ -d "$GDK_PB_SYSDIR/loaders" ] \
    || err "gdk-pixbuf loaders dir not found: $GDK_PB_SYSDIR/loaders"

log "Python: $PYTHON ($PY_VER)"
log "Working directory: $WORK_DIR"

# ─── 1. AppDir structure ──────────────────────────────────────────────────────
log "=== 1. Creating AppDir structure ==="
mkdir -p \
    "$APPDIR/usr/bin" \
    "$APPDIR/usr/lib/$PY_TAG/site-packages" \
    "$APPDIR/usr/lib/$PY_TAG/lib-dynload" \
    "$APPDIR/usr/lib/girepository-1.0" \
    "$APPDIR/usr/lib/gio/modules" \
    "$APPDIR/usr/lib/gdk-pixbuf-2.0/$GDK_PB_VER/loaders" \
    "$APPDIR/usr/share/applications" \
    "$APPDIR/usr/share/icons/hicolor/scalable/apps"

# ─── 2. Install key-mon into AppDir ──────────────────────────────────────────
log "=== 2. Installing key-mon ==="
pip3 install \
    --prefix="$APPDIR/usr" \
    --ignore-installed \
    "git+$REPO_URL"

KEY_MON_BIN="$APPDIR/usr/bin/key-mon"
[ -f "$KEY_MON_BIN" ] && sed -i '1s|.*|#!/usr/bin/env python3|' "$KEY_MON_BIN"

# ─── 3. Python interpreter ────────────────────────────────────────────────────
log "=== 3. Bundling Python $PY_VER interpreter ==="
cp -L "$PYTHON" "$APPDIR/usr/bin/python3"
ln -sf python3 "$APPDIR/usr/bin/python"

PY_SO=$(ldconfig -p 2>/dev/null \
    | awk -v v="libpython${PY_VER}" '$0 ~ v && /x86-64/ {print $NF}' \
    | head -1) || true
if [ -z "$PY_SO" ]; then
    PY_SO=$(find /usr/lib /usr/lib/x86_64-linux-gnu -maxdepth 2 \
            -name "libpython${PY_VER}*.so*" 2>/dev/null | head -1) || true
fi
if [ -n "$PY_SO" ]; then
    cp -L "$PY_SO" "$APPDIR/usr/lib/"
    log "  libpython: $PY_SO"
else
    warn "  libpython${PY_VER}.so not found — Python may be statically linked"
fi

# ─── 4. Python standard library ───────────────────────────────────────────────
log "=== 4. Copying Python stdlib ==="
STDLIB_DIR=$(python3 -c "import sysconfig; print(sysconfig.get_path('stdlib'))")
rsync -a --exclude='__pycache__' --exclude='test/' \
         --exclude='tests/'      --exclude='*.pyc' \
    "$STDLIB_DIR/" "$APPDIR/usr/lib/$PY_TAG/"

[ -d "$STDLIB_DIR/lib-dynload" ] && \
    cp -r "$STDLIB_DIR/lib-dynload/." "$APPDIR/usr/lib/$PY_TAG/lib-dynload/"

# ─── 5. Python packages: gi, cairo, Xlib ─────────────────────────────────────
log "=== 5. Copying Python packages (gi, cairo, Xlib) ==="
OUR_SITE="$APPDIR/usr/lib/$PY_TAG/site-packages"

# gi and cairo: from system dist-packages (installed via apt)
for base_dir in \
    "/usr/lib/python3/dist-packages" \
    "/usr/lib/${PY_TAG}/dist-packages"
do
    [ -d "$base_dir" ] || continue

    for pkg in gi cairo; do
        if [ -d "$base_dir/$pkg" ]; then
            cp -r "$base_dir/$pkg" "$OUR_SITE/"
            log "  Copied dir: $base_dir/$pkg"
        fi
    done

    find "$base_dir" -maxdepth 3 \
        \( -name "_gi*.so" -o -name "_gi_cairo*.so" -o -name "cairo*.so" \) \
        2>/dev/null | while read -r so_file; do
            rel="${so_file#$base_dir/}"
            target="$OUR_SITE/$rel"
            mkdir -p "$(dirname "$target")"
            cp -Lf "$so_file" "$target"
            log "  .so: $rel"
    done
done

# Xlib: install via pip directly into AppDir site-packages
log "  Installing python-xlib via pip into AppDir..."
pip3 install --target="$OUR_SITE" --ignore-installed python-xlib

PYTHONPATH="$OUR_SITE" python3 -c \
    "import Xlib; print('  Xlib OK, version:', Xlib.__version__)" \
    || err "Xlib import failed inside AppDir"

# ─── 6. GObject Introspection typelibs ───────────────────────────────────────
log "=== 6. Copying GObject Introspection typelibs ==="
GI_REPO="/usr/lib/x86_64-linux-gnu/girepository-1.0"
TYPELIBS=(
    Atk-1.0 cairo-1.0
    Gdk-3.0 GdkPixbuf-2.0 GdkX11-3.0
    Gio-2.0 GLib-2.0 GModule-2.0 GObject-2.0
    Gtk-3.0 HarfBuzz-0.0
    Pango-1.0 PangoCairo-1.0 PangoFT2-1.0
    Rsvg-2.0
    xlib-2.0
)
for tl in "${TYPELIBS[@]}"; do
    src="$GI_REPO/${tl}.typelib"
    if [ -f "$src" ]; then
        cp "$src" "$APPDIR/usr/lib/girepository-1.0/"
        log "  typelib: ${tl}.typelib"
    else
        warn "  Missing typelib: ${tl}.typelib"
    fi
done

# ─── 7. Shared libraries (.so) ────────────────────────────────────────────────
log "=== 7. Copying shared libraries ==="
SO_LIBS=(
    # GTK3 / GDK
    libgtk-3.so.0 libgdk-3.so.0
    # GLib / GObject / GIO
    libglib-2.0.so.0 libgobject-2.0.so.0 libgio-2.0.so.0
    libgmodule-2.0.so.0 libgthread-2.0.so.0
    # Cairo
    libcairo.so.2 libcairo-gobject.so.2
    # Pango
    libpango-1.0.so.0 libpangocairo-1.0.so.0
    libpangoft2-1.0.so.0 libpangoxft-1.0.so.0
    # GDK-Pixbuf / ATK
    libgdk_pixbuf-2.0.so.0 libatk-1.0.so.0
    # GObject Introspection
    libgirepository-1.0.so.1
    # SVG rendering — required by the bundled gdk-pixbuf SVG loader
    librsvg-2.so.2
    libcroco-0.6.so.3
    libxml2.so.2
    # Common deps
    libffi.so.7 libpcre.so.3 libepoxy.so.0
    libxkbcommon.so.0
    # X11
    libX11.so.6 libXext.so.6 libXi.so.6
    libXrender.so.1 libXfixes.so.3 libXcursor.so.1
    libXdamage.so.1 libXcomposite.so.1
    libXinerama.so.1 libXrandr.so.2
    # Fonts / FreeType
    libfreetype.so.6 libfontconfig.so.1 libharfbuzz.so.0
    # Misc
    libmount.so.1 libblkid.so.1 libuuid.so.1
    libz.so.1 libpng16.so.16 libpixman-1.so.0
    libbrotlidec.so.1 libbrotlicommon.so.1
    liblzma.so.5
)
for lib in "${SO_LIBS[@]}"; do
    copy_so "$lib"
done

# ─── 8. gdk-pixbuf loaders (SVG, PNG, JPEG, …) ───────────────────────────────
# Without bundling these, the target system's loaders are used, which may pull
# in a newer system librsvg. On Debian 13 that librsvg requires the symbol
# pango_attr_overline_new which does not exist in our bundled Pango from
# Ubuntu 20.04, causing a hard crash on startup.
log "=== 8. Bundling gdk-pixbuf loaders ==="
APPDIR_LOADERS="$APPDIR/usr/lib/gdk-pixbuf-2.0/$GDK_PB_VER/loaders"
cp -L "$GDK_PB_SYSDIR/loaders/"*.so "$APPDIR_LOADERS/"
log "  Copied loaders from $GDK_PB_SYSDIR/loaders/"

# Bundle gdk-pixbuf-query-loaders so the cache can be regenerated at runtime.
# The cache must contain absolute paths that match the actual mount point of
# the AppImage, which is only known at launch time — so we cannot pre-generate
# it during the build.
cp -L "$GDK_QB_BIN" "$APPDIR/usr/bin/gdk-pixbuf-query-loaders"
log "  Copied gdk-pixbuf-query-loaders"

# ─── 9. GIO modules: empty dir to block system gvfs ──────────────────────────
# On systems with newer glib (e.g. Debian 13) the system libgvfsdbus.so is
# loaded as a GIO module but immediately fails with:
#   "undefined symbol: g_task_set_static_name"
# because our bundled libglib is older. Pointing GIO_MODULE_DIR at an empty
# directory inside the AppImage prevents any system GIO module from loading.
# The directory $APPDIR/usr/lib/gio/modules was created in step 1 and is
# intentionally left empty.
log "=== 9. GIO isolation ==="
log "  Empty GIO module dir ready — system gvfs modules will not be loaded"

# ─── 10. Icon and .desktop file ───────────────────────────────────────────────
log "=== 10. Setting up icon and .desktop ==="
ICON_FILE=$(find "$APPDIR/usr" -name "*.svg" 2>/dev/null | head -1)
if [ -n "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$APPDIR/key-mon.svg"
    cp "$ICON_FILE" "$APPDIR/.DirIcon"
else
    warn "No SVG icon found — downloading fallback from repo..."
    wget -q -O "$APPDIR/key-mon.svg" \
        "https://github.com/setaur/key-mon/raw/master/icons/svg/ctrl-small.svg" \
        2>/dev/null || touch "$APPDIR/key-mon.svg"
    cp "$APPDIR/key-mon.svg" "$APPDIR/.DirIcon"
fi

cat > "$APPDIR/key-mon.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Key-Mon
GenericName=Key and Mouse Monitor
Comment=Displays keyboard and mouse activity (Xorg only)
Exec=key-mon
Icon=key-mon
Type=Application
Categories=Utility;Accessibility;
Keywords=keyboard;mouse;screencast;
DESKTOP

cp "$APPDIR/key-mon.desktop" "$APPDIR/usr/share/applications/key-mon.desktop"

# ─── 11. AppRun entry point ───────────────────────────────────────────────────
log "=== 11. Writing AppRun ==="
cat > "$APPDIR/AppRun" << APPRUN
#!/bin/bash
# AppRun — entry point executed when the AppImage is launched
HERE="\$(dirname "\$(readlink -f "\$0")")"

# ── Python ────────────────────────────────────────────────────────────────────
export PYTHONHOME="\$HERE/usr"
export PYTHONPATH="\$HERE/usr/lib/${PY_TAG}/site-packages"

# ── Shared libraries ──────────────────────────────────────────────────────────
export LD_LIBRARY_PATH="\$HERE/usr/lib:\${LD_LIBRARY_PATH:-}"

# ── GObject Introspection typelibs ────────────────────────────────────────────
export GI_TYPELIB_PATH="\$HERE/usr/lib/girepository-1.0:\${GI_TYPELIB_PATH:-}"

# ── GIO modules ───────────────────────────────────────────────────────────────
# Point to the empty bundled directory so no system GIO module (e.g. gvfs) is
# loaded. On Debian 13 the system libgvfsdbus.so triggers:
#   "undefined symbol: g_task_set_static_name"
# because our bundled libglib from Ubuntu 20.04 is older.
export GIO_MODULE_DIR="\$HERE/usr/lib/gio/modules"

# ── gdk-pixbuf loaders ────────────────────────────────────────────────────────
# We use the loaders built against Ubuntu 20.04's librsvg and libpango.
# The loaders.cache must contain absolute paths matching the actual AppImage
# mount point (unknown at build time), so we regenerate it on every launch
# into a temporary file. The AppImage filesystem is read-only, so we cannot
# write the cache there.
# Without this, the target system's SVG loader is used. On Debian 13 it pulls
# a newer librsvg that requires pango_attr_overline_new — missing in our older
# bundled Pango — and crashes with "undefined symbol".
GDK_PB_LOADERS_DIR="\$HERE/usr/lib/gdk-pixbuf-2.0/${GDK_PB_VER}/loaders"
GDK_PB_CACHE="\$(mktemp /tmp/keymon-pb-XXXXXX.cache)"
GDK_PIXBUF_MODULEDIR="\$GDK_PB_LOADERS_DIR" \
    "\$HERE/usr/bin/gdk-pixbuf-query-loaders" > "\$GDK_PB_CACHE" 2>/dev/null \
    || true
export GDK_PIXBUF_MODULE_FILE="\$GDK_PB_CACHE"
export GDK_PIXBUF_MODULEDIR="\$GDK_PB_LOADERS_DIR"
trap 'rm -f "\$GDK_PB_CACHE"' EXIT

# ── GTK: fall back to system themes and icons ─────────────────────────────────
export XDG_DATA_DIRS="\$HERE/usr/share:/usr/share:\${XDG_DATA_DIRS:-/usr/local/share}"

exec "\$HERE/usr/bin/python3" -m keymon.key_mon "\$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# ─── 12. linuxdeploy — collect transitive .so dependencies ───────────────────
log "=== 12. Running linuxdeploy ==="
cd "$WORK_DIR"
wget -q --show-progress -O linuxdeploy \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
chmod +x linuxdeploy

./linuxdeploy --appdir "$APPDIR" -e "$APPDIR/usr/bin/python3" 2>&1 \
    | grep -v "^$" || warn "linuxdeploy reported errors (usually non-fatal)"

find "$APPDIR/usr/lib" -name "*.so*" -type f 2>/dev/null | while read -r so; do
    ./linuxdeploy --appdir "$APPDIR" -e "$so" 2>/dev/null || true
done

# ─── 13. Build the AppImage ───────────────────────────────────────────────────
log "=== 13. Building AppImage ==="
wget -q --show-progress -O appimagetool \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
chmod +x appimagetool

VERSION=$(key-mon -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+([0-9.]+)?' | head -1) \
    || VERSION=$("$APPDIR/usr/bin/python3" -m keymon.key_mon -v 2>/dev/null \
       | grep -oE '[0-9]+\.[0-9]+([0-9.]+)?' | head -1) \
    || VERSION="1.20"

OUTPUT="$HOME/${APP_NAME}-${ARCH}_v${VERSION}.AppImage"

log "  Packing: $APPDIR  →  $OUTPUT"
ARCH=x86_64 ./appimagetool "$APPDIR" "$OUTPUT"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
log "╔══════════════════════════════════════════════════════════╗"
log "║  AppImage ready!                                         ║"
log "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  File:    $OUTPUT"
echo "  Size:    $(du -sh "$OUTPUT" 2>/dev/null | cut -f1)"
echo ""
echo "  Run with:"
echo "    chmod +x $OUTPUT"
echo "    $OUTPUT"
echo ""
log "Remove temp directory when done:"
echo "  rm -rf $WORK_DIR"
