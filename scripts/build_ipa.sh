#!/bin/bash
# ---------------------------------------------------------------------------
# «Мои смены» — сборка .ipa на Mac (единственная платформа, где это возможно).
#
# Требования: macOS 14+, Xcode 16+ (xcode-select --install / App Store),
#             Flutter SDK в PATH, CocoaPods (sudo gem install cocoapods).
#
# Использование:
#   ./scripts/build_ipa.sh                 # подписанный .ipa (development)
#   ./scripts/build_ipa.sh unsigned        # .ipa без подписи (для Sideloadly)
#   ./scripts/build_ipa.sh app-store       # .ipa для App Store Connect
# ---------------------------------------------------------------------------
set -euo pipefail

MODE="${1:-development}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ОШИБКА: .ipa собирается только на macOS (нужен Xcode). Текущая ОС: $(uname -s)"
  echo "Варианты: 1) любой Mac, 2) GitHub Actions workflow .github/workflows/ios-ipa.yml,"
  echo "          3) облачный Mac (MacinCloud, Codemagic, Bitrise)."
  exit 1
fi

command -v flutter >/dev/null || { echo "Flutter не найден в PATH"; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode не найден (xcode-select --install)"; exit 1; }

echo "==> Xcode: $(xcodebuild -version | head -n 1)"

echo "==> flutter pub get"
flutter pub get

rm -rf build/ios/ipa build/ios/ipa-unsigned

if [[ "$MODE" == "unsigned" ]]; then
  echo "==> Сборка без подписи"
  flutter build ios --release --no-codesign

  APP_PATH="build/ios/iphoneos/Runner.app"
  [[ -d "$APP_PATH" ]] || { echo "Не найден $APP_PATH"; exit 1; }

  mkdir -p build/ios/unsigned/Payload build/ios/ipa-unsigned
  cp -R "$APP_PATH" build/ios/unsigned/Payload/Runner.app
  ( cd build/ios/unsigned && zip -qry "../../ipa-unsigned/MyShifts-unsigned.ipa" Payload )

  echo "==> Готово: build/ios/ipa-unsigned/MyShifts-unsigned.ipa"
  echo "    Подписать своим Apple ID: Sideloadly / AltStore / iOS App Signer (7 дней на free-аккаунте)."
  exit 0
fi

echo "==> Сборка подписанного .ipa (method=$MODE)"

# Подставляем способ экспорта в ExportOptions.plist
EXPORT_PLIST="ios/ExportOptions.plist"
sed -i '' "s|<string>development</string>|<string>${MODE}</string>|" "$EXPORT_PLIST" || true

flutter build ipa \
  --release \
  --export-options-plist="$EXPORT_PLIST" \
  --build-name=1.0.0 \
  --build-number="$(date +%Y%m%d%H%M)"

echo "==> Готово:"
ls -lh build/ios/ipa/*.ipa

echo ""
echo "Если Xcode ругается на подпись:"
echo "  1) Откройте ios/Runner.xcworkspace в Xcode."
echo "  2) Выберите проект Runner → цель Runner → вкладка «Signing & Capabilities»"
echo "     (Подпись и возможности) → включите «Automatically manage signing»"
echo "     (Автоматически управлять подписью) и укажите свою Team."
echo "  3) Xcode → «Settings…» (Настройки) → «Accounts» (Учётные записи) → добавьте Apple ID."
