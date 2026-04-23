#!/bin/bash
#create Appimage "key-mon" x86_64 binary from already installed via pipx key-mon
#key-mon: https://github.com/scottkirkwood/key-mon

set -e
set -o pipefail

WORK_DIR="/tmp/keymon-appimage-$$"
VENV_PATH="$HOME/.local/share/pipx/venvs/key-mon"
ICON_PATH="$VENV_PATH"/lib/python3.13/site-packages/keymon/themes/clear/ctrl-small.svg
VERSION="$(key-mon -v | head -n1 | grep -oE '[0-9]+[0-9.]*[0-9]+')"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

mkdir -p keymon.AppDir/usr/{bin,share/applications,share/icons/hicolor/128x128/apps}
cp -r "$VENV_PATH"/* keymon.AppDir/usr/

cat > keymon.AppDir/key-mon.desktop << 'EOF'
[Desktop Entry]
Name=Key-Mon
Exec=key-mon
Icon=key-mon
Type=Application
Categories=Utility;
EOF

#cp /usr/share/icons/Adwaita/scalable/devices/input-keyboard.svg keymon.AppDir/key-mon.svg
#convert -size 128x128 keymon.AppDir/key-mon.svg keymon.AppDir/.DirIcon 2>/dev/null || touch keymon.AppDir/.DirIcon
cp "$ICON_PATH" keymon.AppDir/.DirIcon
cp keymon.AppDir/.DirIcon keymon.AppDir/key-mon.svg


cat > keymon.AppDir/AppRun << 'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export PYTHONPATH="$HERE/usr/lib/python3.13/site-packages:$PYTHONPATH"
export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/lib:$LD_LIBRARY_PATH"
export GI_TYPELIB_PATH="$HERE/usr/lib/girepository-1.0:$GI_TYPELIB_PATH"
exec "$HERE/usr/bin/python" -m keymon.key_mon "$@"
EOF
chmod +x keymon.AppDir/AppRun

wget -q https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x appimagetool-x86_64.AppImage

ARCH=x86_64 ./appimagetool-x86_64.AppImage keymon.AppDir

OUTPUT_FILE="$(find "$WORK_DIR" -maxdepth 1 -type f -iname '*.AppImage' -print -quit)"
filename=$(basename -- "$OUTPUT_FILE")
extension="${filename##*.}"
filename="${filename%.*}"
OUTPUT_FILE2="${WORK_DIR}/${filename}_v${VERSION}.AppImage"

mv -v "$OUTPUT_FILE" "$OUTPUT_FILE2"

echo -n "Done: "
realpath "$OUTPUT_FILE2"
