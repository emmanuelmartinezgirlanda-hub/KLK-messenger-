#!/usr/bin/env bash
# Crea la carpeta ios/ y pone el nombre y el icono de la app.
set -euo pipefail
cd "$(dirname "$0")"
flutter create --platforms ios --org com.emmanuelmartinez --project-name ingles_diario .
rm -f test/widget_test.dart
PL=ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Speakazo" "$PL" || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Speakazo" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Speakazo" "$PL" || true
flutter pub get
dart run flutter_launcher_icons
