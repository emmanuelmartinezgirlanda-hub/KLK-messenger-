#!/usr/bin/env bash
# Genera y ajusta las carpetas nativas (ios/ y android/) de KLK.
# Lo ejecuta Codemagic en cada compilación; también sirve en un Mac propio.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.klkapp.klk"

# 1. Carpetas nativas (solo si faltan; no pisa cambios propios)
if [ ! -d ios ] || [ ! -d android ]; then
  flutter create . --org com.klkapp --project-name klk --platforms ios,android
  rm -f test/widget_test.dart   # test de ejemplo de la plantilla
fi

flutter pub get

# 2. Icono
dart run flutter_launcher_icons

# 3. iOS: nombre visible, iOS mínimo 13 y textos de permisos
PLIST=ios/Runner/Info.plist
if command -v /usr/libexec/PlistBuddy >/dev/null; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName KLK" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string KLK" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName KLK" "$PLIST" 2>/dev/null || true
fi
# Permisos (textos que ve el usuario cuando KLK los pide)
if command -v plutil >/dev/null; then
  addkey() { plutil -replace "$1" -string "$2" "$PLIST"; }
  addkey NSCameraUsageDescription "KLK usa la cámara para que hagas fotos y vídeos y los envíes a tu gente."
  addkey NSMicrophoneUsageDescription "KLK usa el micrófono para grabar notas de voz y vídeos."
  addkey NSPhotoLibraryUsageDescription "KLK accede a tus fotos para que puedas enviarlas en calidad original."
  addkey NSPhotoLibraryAddUsageDescription "KLK guarda en tu galería las fotos que decidas descargar."
  addkey NSLocationWhenInUseUsageDescription "KLK usa tu ubicación solo cuando decides enviarla en un chat."
  # Que la llamada siga sonando si sales un momento de KLK
  plutil -replace UIBackgroundModes -json '["audio"]' "$PLIST"
fi
sed -i.bak "s/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]*;/IPHONEOS_DEPLOYMENT_TARGET = 13.0;/g" ios/Runner.xcodeproj/project.pbxproj
sed -i.bak "s/PRODUCT_BUNDLE_IDENTIFIER = [A-Za-z0-9.]*klk;/PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID;/g" ios/Runner.xcodeproj/project.pbxproj
if [ -f ios/Podfile ]; then
  sed -i.bak "s/^# platform :ios.*/platform :ios, '13.0'/" ios/Podfile
fi

# 4. Android: nombre visible y permiso de Internet en la versión final
MANIFEST=android/app/src/main/AndroidManifest.xml
sed -i.bak 's/android:label="[^"]*"/android:label="KLK"/' "$MANIFEST"
if ! grep -q "android.permission.INTERNET" "$MANIFEST"; then
  perl -0pi -e 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$MANIFEST"
fi

for perm in RECORD_AUDIO ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION CAMERA MODIFY_AUDIO_SETTINGS BLUETOOTH_CONNECT; do
  if ! grep -q "android.permission.$perm" "$MANIFEST"; then
    perl -0pi -e "s#<application#<uses-permission android:name=\"android.permission.$perm\"/>\n    <application#" "$MANIFEST"
  fi
done

# Android: versión mínima 23 (la necesitan la grabadora y la ubicación)
for g in android/app/build.gradle android/app/build.gradle.kts; do
  if [ -f "$g" ]; then
    sed -i.bak -E 's/minSdk(Version)? *=? *flutter\.minSdkVersion/minSdk = 23/' "$g"
  fi
done

find ios android -name "*.bak" -delete
echo "Carpetas nativas listas (bundle: $BUNDLE_ID)"
