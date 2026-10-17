#!/bin/bash
# Buduje MacCare AI jako natywną aplikację macOS (bez Xcode).
# Użycie: ./Scripts/build_app.sh [--install] [--debug] [--dev-identity]
#   → build/MacCare AI.app, domyślnie podpis AD-HOC (zmienia się co build ⇒ macOS pyta o dostępy od nowa)
#   |   --dev-identity: podpis stałą lokalną tożsamością z .signing/ (wymaga wcześniejszej decyzji właściciela – patrz one_time_setup.sh)
#   |   --install kopiuje do /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
# --screenshots: build do zrzutów ekranu z kodem `ScreenshotDriver` (P3-3) – osobny katalog budowania, żeby nie mieszać z wydaniem.
SWIFT_EXTRA=()
for a in "$@"; do
  [[ "$a" == "--debug" ]] && CONFIG=debug
  [[ "$a" == "--screenshots" ]] && SWIFT_EXTRA=(--scratch-path .build-screens -Xswiftc -DMACCARE_SCREENSHOTS)
done
APP_NAME="MacCare AI"
APP="build/${APP_NAME}.app"
BUNDLE_ID="io.github.u7464145221-max.maccare"
VERSION="${MACCARE_VERSION:-0.2.5}"

# Decyzja właściciela 15.10.2026: TYLKO Apple Silicon (arm64) – bez budowy uniwersalnej i bez wsparcia Intela.
echo "== swift build -c $CONFIG (arm64)"
swift build -c "$CONFIG" --arch arm64 --product MacCareApp ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"}
BIN="$(swift build -c "$CONFIG" --arch arm64 --product MacCareApp ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"} --show-bin-path)/MacCareApp"
[[ -x "$BIN" ]] || { echo "Brak pliku wykonywalnego: $BIN" >&2; exit 1; }
ARCHS="$(lipo -archs "$BIN")"
[[ "$ARCHS" == "arm64" ]] || { echo "Plik wykonywalny ma architektury „$ARCHS” – dozwolona wyłącznie arm64 (tylko Apple Silicon)" >&2; exit 1; }

echo "== pakiet $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacCareApp"

echo "== ikona"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swift Scripts/make_icon.swift "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Lokalizacje (i18n): pl – język źródłowy (klucze), en – tłumaczenie. SwiftUI szuka tekstów w Bundle.main, więc .lproj trafiają do Contents/Resources.
cp -R Sources/MacCareApp/Localization/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>MacCareApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>pl</string>
  <key>CFBundleLocalizations</key><array><string>pl</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSDesktopFolderUsageDescription</key><string>MacCare AI tylko CZYTA nazwy i rozmiary, żeby pokazać mapę dysku. Niczego nie zmienia.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>MacCare AI tylko CZYTA nazwy i rozmiary, żeby pokazać mapę dysku. Niczego nie zmienia.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>MacCare AI tylko CZYTA nazwy i rozmiary, żeby znaleźć duże i stare pliki. Niczego nie zmienia.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>MacCare AI tylko CZYTA rozmiary na dyskach zewnętrznych. Niczego nie zmienia.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>MacCare AI tylko CZYTA rozmiary na dyskach sieciowych. Niczego nie zmienia.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST

# Prywatność wydania: bez symboli debugowania – linker wpisuje do nich pełne ścieżki budowania (z nazwą konta). Po usunięciu – twarda kontrola
# PO BAJTACH (nie `strings`, który tego nie wykrył): ścieżka domowa i nazwa konta nie mogą zostać w pliku programu.
echo "== bez symboli debugowania"
strip -S -x "$APP/Contents/MacOS/MacCareApp"
python3 - "$APP/Contents/MacOS/MacCareApp" "$HOME" "$(id -un)" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
for needle in {sys.argv[2], sys.argv[3], sys.argv[3].lower()}:          # ścieżka katalogu tymczasowego też zawiera nazwę konta
    if len(needle) >= 3 and needle.encode().lower() in data.lower():
        sys.exit(f"STOP: plik programu zawiera „{needle}” – wydanie zablokowane")
print("prywatność pliku programu: OK (brak ścieżki domowej i nazwy konta)")
PY
# P3-3: wydanie bez trybu zrzutów – znacznik sterownika (nazwa funkcji ładowanej przez `dlsym`) nie może być w pliku programu
if [[ ${#SWIFT_EXTRA[@]} -eq 0 && "$CONFIG" == "release" ]] && grep -aq "CGWindowListCreateImage" "$APP/Contents/MacOS/MacCareApp"; then
  echo "STOP: wydanie zawiera kod sterownika zrzutów (P3-3)" >&2; exit 1
fi

echo "== podpis"
SIGN_NAME="MacCare AI Local Dev"; KC="$PWD/.signing/maccare-dev.keychain-db"
if [[ " $* " == *" --dev-identity "* ]]; then
  if ./Scripts/setup_signing.sh >/dev/null 2>&1 && security unlock-keychain -p "$(cat .signing/keychain.pw)" "$KC" 2>/dev/null \
     && codesign --force --deep --options runtime --sign "$SIGN_NAME" --keychain "$KC" "$APP" 2>/dev/null; then
    echo "podpisano stałą tożsamością „$SIGN_NAME”"
  else
    echo "UWAGA: stała tożsamość niedostępna (niezaufany certyfikat?) – podpis ad-hoc. Patrz Scripts/one_time_setup.sh." >&2
    codesign --force --deep --options runtime --sign - "$APP"
  fi
else
  codesign --force --deep --options runtime --sign - "$APP"
  echo "podpis ad-hoc (domyślnie). Stała tożsamość: --dev-identity"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | head -2
# Audyt 16.10 (2.5): Hardened Runtime – bez niego inny program z konta użytkownika mógłby wstrzyknąć bibliotekę (DYLD_INSERT_LIBRARIES) i korzystać
# z Pełnego dostępu do dysku przyznanego MacCare. Działa także przy podpisie ad-hoc (Developer ID i notaryzacja – osobno, decyzja właściciela).
SIGINFO="$(codesign -dv "$APP" 2>&1)"                     # najpierw całość do zmiennej: `grep -q` w potoku z pipefail dawał sporadyczny SIGPIPE
[[ "$SIGINFO" == *"flags="*"runtime"* ]] || { echo "STOP: podpis bez Hardened Runtime" >&2; exit 1; }
echo "Hardened Runtime: włączony"
codesign -dr - "$APP" 2>&1 | grep designated
echo "Zbudowano: $APP"

if [[ " $* " == *" --install "* ]]; then
  DEST="/Applications/${APP_NAME}.app"
  rm -rf "$DEST"; cp -R "$APP" /Applications/
  echo "Zainstalowano: $DEST"
fi
