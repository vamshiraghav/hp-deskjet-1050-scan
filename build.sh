#!/usr/bin/env bash
# Build the DeskJet 1050 scanner backend and install the Mac app.
# HPLIP itself is downloaded from SourceForge at build time and is not
# committed to this repository.

set -euo pipefail

HPLIP_VER="${HPLIP_VER:-3.25.8}"
PREFIX="${PREFIX:-$(brew --prefix)}"
WORK="${WORK:-/tmp/dj1050-hplip-build}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="https://downloads.sourceforge.net/project/hplip/hplip/${HPLIP_VER}/hplip-${HPLIP_VER}.tar.gz"
APP="$HOME/Applications/DeskJet 1050 Scan.app"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v brew >/dev/null || die "Homebrew is required"
command -v curl >/dev/null || die "curl is required"
command -v python3 >/dev/null || die "python3 is required"
command -v clang >/dev/null || die "clang is required (Xcode or the command-line tools)"

for pkg in libusb sane-backends pkg-config; do
    if ! brew list --formula "$pkg" >/dev/null 2>&1; then
        log "installing $pkg"
        brew install "$pkg"
    fi
done

mkdir -p "$WORK"
cd "$WORK"
if [[ ! -f "hplip-${HPLIP_VER}.tar.gz" ]]; then
    log "downloading HPLIP ${HPLIP_VER}"
    curl -L --retry 3 --retry-delay 2 -o "hplip-${HPLIP_VER}.tar.gz" "$URL"
fi
if [[ ! -d "hplip-${HPLIP_VER}" ]]; then
    log "extracting HPLIP"
    tar xzf "hplip-${HPLIP_VER}.tar.gz"
fi
cd "hplip-${HPLIP_VER}"

log "applying macOS and DeskJet 1050 patches"
cp "$ROOT/stubs/orblitei.h" scan/sane/orblitei.h
cp "$ROOT/stubs/orblite.c" scan/sane/orblite.c
if [[ ! -f .dj1050-patched ]]; then
    for patch_file in "$ROOT"/patches/*.patch; do
        if ! patch -p1 --forward --silent < "$patch_file"; then
            echo "patch failed: $(basename "$patch_file")" >&2
            patch -p1 --forward < "$patch_file" || true
            exit 1
        fi
    done
    touch .dj1050-patched
fi

python3 - <<'PY'
from pathlib import Path
path = Path("data/models/models.dat")
text = path.read_text()
start = text.find("[deskjet_1050_j410_series]")
if start < 0:
    raise SystemExit("models.dat has no DeskJet 1050 J410 record")
end = text.find("\n[", start + 2)
section = text[start:end]
aliases = {
    "model5": "HP Deskjet 1050 J410 series",
    "model6": "Deskjet 1050 J410 series",
    "model7": "HP Deskjet 1050 j410 series",
}
missing = [f"{key}={value}" for key, value in aliases.items() if f"{key}=" not in section]
if not missing:
    raise SystemExit(0)
anchor = "model4=HP Deskjet 1056 All-in-One Printer -J410a\n"
if anchor not in section:
    raise SystemExit("could not find model4 in the 1050 record")
section = section.replace(anchor, anchor + "\n".join(missing) + "\n", 1)
for key, required in (("scan-type", "7"), ("io-mfp-mode", "1"), ("plugin", "0")):
    if f"{key}={required}" not in section:
        raise SystemExit(f"DeskJet 1050 record is not {key}={required}")
path.write_text(text[:start] + section + text[end:])
print("added model aliases:", ", ".join(missing))
PY

log "configuring HPLIP scan backend"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CFLAGS="-I$PREFIX/include -I$PREFIX/include/libusb-1.0 -I$PREFIX/include/sane -D_DARWIN_C_SOURCE -Wno-error -Wno-implicit-function-declaration -Wno-int-conversion -fcommon"
export CPPFLAGS="-I$PREFIX/include -I$PREFIX/include/libusb-1.0 -I$PREFIX/include/sane"
export LDFLAGS="-L$PREFIX/lib"
./configure --prefix="$PREFIX" \
    --enable-lite-build \
    --disable-network-build \
    --disable-fax-build \
    --disable-gui-build \
    --disable-doc-build \
    --disable-dbus-build \
    --disable-pp-build \
    --disable-policykit \
    --disable-imageProcessor-build \
    --enable-scan-build \
    --disable-cups-drv-install \
    --disable-foomatic-drv-install \
    --disable-foomatic-ppd-install \
    --disable-cups-ppd-install

python3 - "$PREFIX" <<'PY'
import pathlib, sys
prefix = sys.argv[1]
makefile = pathlib.Path("Makefile")
kept = []
for line in makefile.read_text().splitlines(keepends=True):
    stripped = line.strip()
    if stripped in {"libhpipp.la", "libhpipp.la \\"}:
        continue
    kept.append(line.replace("hplip_confdir = /etc/hp", f"hplip_confdir = {prefix}/etc/hp"))
makefile.write_text("".join(kept))
PY

log "compiling hpaio"
make -j"$(sysctl -n hw.ncpu)" libhpmud.la libhpip.la libsane-hpaio.la
[[ -f .libs/libsane-hpaio.1.so ]] || die "libsane-hpaio.1.so was not produced"

log "installing backend into $PREFIX"
mkdir -p "$PREFIX/lib/sane" "$PREFIX/etc/sane.d" "$PREFIX/etc/hp" \
    "$PREFIX/share/hplip/data/models/unreleased" "$PREFIX/bin"
cp .libs/libhpmud.0.dylib "$PREFIX/lib/"
cp .libs/libhpip.0.dylib "$PREFIX/lib/"
cp .libs/libsane-hpaio.1.so "$PREFIX/lib/sane/"
ln -sfn libhpmud.0.dylib "$PREFIX/lib/libhpmud.dylib"
ln -sfn libhpip.0.dylib "$PREFIX/lib/libhpip.dylib"
ln -sfn libsane-hpaio.1.so "$PREFIX/lib/sane/libsane-hpaio.so"
cp hplip.conf "$PREFIX/etc/hp/"
cp data/models/models.dat "$PREFIX/share/hplip/data/models/"
if [[ -f data/models/unreleased/unreleased.dat ]]; then
    cp data/models/unreleased/unreleased.dat "$PREFIX/share/hplip/data/models/unreleased/"
else
    : > "$PREFIX/share/hplip/data/models/unreleased/unreleased.dat"
fi

python3 - <<PY
import pathlib, subprocess
prefix = pathlib.Path("${PREFIX}")
files = [
    prefix / "lib/libhpmud.0.dylib",
    prefix / "lib/libhpip.0.dylib",
    prefix / "lib/sane/libsane-hpaio.1.so",
]
for path in files:
    subprocess.check_call(["install_name_tool", "-id", str(path), str(path)])
replacements = {
    "libhpmud": prefix / "lib/libhpmud.0.dylib",
    "libhpip": prefix / "lib/libhpip.0.dylib",
}
for path in files:
    listing = subprocess.check_output(["otool", "-L", str(path)], text=True)
    for line in listing.splitlines()[1:]:
        dep = line.strip().split(" ", 1)[0]
        for name, target in replacements.items():
            if name in dep and dep != str(target):
                subprocess.check_call(["install_name_tool", "-change", dep, str(target), str(path)])
PY

dll="$PREFIX/etc/sane.d/dll.conf"
if [[ ! -f "$dll" ]] || ! grep -qx 'hpaio' "$dll"; then
    echo hpaio >> "$dll"
fi
install -m 0755 "$ROOT/bin/dj1050-scan" "$PREFIX/bin/dj1050-scan"

log "building DeskJet 1050 Scan.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 \
    -o "$APP/Contents/MacOS/DeskJet1050Scan" \
    "$ROOT/app/Sources/DeskJet1050Scan/App.swift"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo
echo "Scanner backend installed."
echo "  App:     $APP"
echo "  Command: dj1050-scan doctor"
echo "Plug in the DeskJet 1050, then open the app or run:  dj1050-scan"
echo "Image Capture:  dj1050-scan bridge --install-agent"
