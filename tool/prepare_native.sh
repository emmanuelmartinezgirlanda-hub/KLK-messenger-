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

# 3. iOS: nombre visible, iOS mínimo 15.5 y textos de permisos
PLIST=ios/Runner/Info.plist
if command -v /usr/libexec/PlistBuddy >/dev/null; then
  # Nombre bajo el icono: "KLK messenger"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'KLK messenger'" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleName KLK" "$PLIST" 2>/dev/null || true
fi
# Permisos (textos que ve el usuario cuando KLK los pide)
if command -v plutil >/dev/null; then
  addkey() { plutil -replace "$1" -string "$2" "$PLIST"; }
  addkey CFBundleDisplayName "KLK messenger"
  addkey NSCameraUsageDescription "KLK usa la cámara para que hagas fotos y vídeos y los envíes a tu gente."
  addkey NSMicrophoneUsageDescription "KLK usa el micrófono para grabar notas de voz y vídeos."
  addkey NSPhotoLibraryUsageDescription "KLK accede a tus fotos para que puedas enviarlas en calidad original."
  addkey NSPhotoLibraryAddUsageDescription "KLK guarda en tu galería las fotos que decidas descargar."
  addkey NSContactsUsageDescription "KLK mira tu agenda para mostrarte qué contactos ya usan KLK. Tu agenda no se guarda en nuestros servidores."
  addkey NSLocationWhenInUseUsageDescription "KLK usa tu ubicación solo cuando decides enviarla o compartirla en tiempo real en un chat."
  addkey NSLocationAlwaysAndWhenInUseUsageDescription "KLK usa tu ubicación solo cuando decides enviarla o compartirla en tiempo real en un chat. No la usa en segundo plano para nada más."
  addkey NSFaceIDUsageDescription "KLK usa Face ID para que solo tú puedas abrir tus chats."
  addkey NSSpeechRecognitionUsageDescription "KLK pasa a texto las notas de voz dentro de tu iPhone, sin enviarlas a ningún servidor."
  # Que la llamada siga sonando si sales un momento de KLK
  plutil -replace UIBackgroundModes -json '["audio"]' "$PLIST"
  # Cifrado: solo algoritmos estándar (exento) y sin Francia. Así App Store
  # Connect no vuelve a preguntar «Falta información de exportación».
  plutil -replace ITSAppUsesNonExemptEncryption -bool NO "$PLIST"
fi
# iOS 15.5 mínimo: lo exige el traductor de Google ML Kit
sed -i.bak "s/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]*;/IPHONEOS_DEPLOYMENT_TARGET = 15.5;/g" ios/Runner.xcodeproj/project.pbxproj
# Solo iPhone (en iPad se abre la versión de iPhone): así la App Store no pide capturas de iPad
sed -i.bak 's/TARGETED_DEVICE_FAMILY = "1,2";/TARGETED_DEVICE_FAMILY = 1;/g' ios/Runner.xcodeproj/project.pbxproj
sed -i.bak "s/PRODUCT_BUNDLE_IDENTIFIER = [A-Za-z0-9.]*klk;/PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID;/g" ios/Runner.xcodeproj/project.pbxproj
# KLK Plus: iconos alternativos de la app (iPhone). Van en el catálogo de imágenes
# y Xcode los apunta solos en el Info.plist con ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
if [ -d ios/Runner/Assets.xcassets ]; then
  for pair in "noche:KLK-Noche" "oro:KLK-Oro" "bandera:KLK-Bandera"; do
    src="assets/icon/alt/${pair%%:*}.png"; set_name="${pair##*:}"
    dir="ios/Runner/Assets.xcassets/${set_name}.appiconset"
    mkdir -p "$dir" && cp "$src" "$dir/icon.png"
    cat > "$dir/Contents.json" <<'JSON'
{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
JSON
  done
  if ! grep -q "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES" ios/Runner.xcodeproj/project.pbxproj; then
    perl -pi -e 's#^(\s*)ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;#$1ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n$1ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "KLK-Noche KLK-Oro KLK-Bandera";#' ios/Runner.xcodeproj/project.pbxproj
  fi
  grep -c "ALTERNATE_APPICON_NAMES" ios/Runner.xcodeproj/project.pbxproj || true
fi
# Avisos push (APNs): permiso "aps-environment" en la app de iPhone.
# Solo con KLK_PUSH=1 (hay que activar antes "Push Notifications" en el App ID
# de developer.apple.com; si no, la firma de Codemagic falla).
if [ "${KLK_PUSH:-0}" = "1" ]; then
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>aps-environment</key><string>production</string></dict></plist>' \
    > ios/Runner/Runner.entitlements
  if ! grep -q "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements" ios/Runner.xcodeproj/project.pbxproj; then
    perl -pi -e "s#^(\s*)PRODUCT_BUNDLE_IDENTIFIER = \Q$BUNDLE_ID\E;#\1CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\n\1PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID;#" ios/Runner.xcodeproj/project.pbxproj
  fi
  grep -c "CODE_SIGN_ENTITLEMENTS" ios/Runner.xcodeproj/project.pbxproj || true
fi
if [ -f ios/Podfile ]; then
  sed -i.bak "s/^# platform :ios.*/platform :ios, '15.5'/" ios/Podfile
fi

# 4. Android: nombre visible y permiso de Internet en la versión final
MANIFEST=android/app/src/main/AndroidManifest.xml
sed -i.bak 's/android:label="[^"]*"/android:label="KLK messenger"/' "$MANIFEST"
if ! grep -q "android.permission.INTERNET" "$MANIFEST"; then
  perl -0pi -e 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$MANIFEST"
fi

# Google Play: KLK no necesita leer toda la galería (elige fotos con el selector
# del sistema), así que quitamos los permisos amplios que añade algún plugin.
# Sin esto Google pide la «declaración de permisos de fotos y vídeos».
if ! grep -q 'xmlns:tools' "$MANIFEST"; then
  perl -0pi -e 's#<manifest #<manifest xmlns:tools="http://schemas.android.com/tools" #' "$MANIFEST"
fi
for perm in READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_MEDIA_AUDIO READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE; do
  if ! grep -q "android.permission.$perm\" tools:node=\"remove\"" "$MANIFEST"; then
    perl -0pi -e "s#<application#<uses-permission android:name=\"android.permission.$perm\" tools:node=\"remove\"/>\n    <application#" "$MANIFEST"
  fi
done

# Seguridad: que Android no copie los chats a la nube de Google por su cuenta
# (KLK tiene su propia copia cifrada con contraseña).
if ! grep -q "android:allowBackup" "$MANIFEST"; then
  perl -0pi -e 's#<application#<application android:allowBackup="false" android:fullBackupContent="false"#' "$MANIFEST"
fi

for perm in RECORD_AUDIO ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION CAMERA MODIFY_AUDIO_SETTINGS BLUETOOTH_CONNECT READ_CONTACTS USE_BIOMETRIC; do
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

# Android: Google Play exige apuntar a Android 16 (API 36) desde agosto de 2026
for g in android/app/build.gradle.kts android/app/build.gradle; do
  if [ -f "$g" ]; then
    sed -i.bak -E 's/targetSdk(Version)? *=? *flutter\.targetSdkVersion/targetSdk = 36/; s/compileSdk(Version)? *=? *flutter\.compileSdkVersion/compileSdk = 36/' "$g"
  fi
done

# Android: firma de la versión para Google Play. Codemagic deja la clave en
# CM_KEYSTORE_PATH (+ contraseñas); sin ella se firma con la clave de pruebas.
G=android/app/build.gradle.kts
if [ -f "$G" ] && ! grep -q "CM_KEYSTORE_PATH" "$G"; then
  perl -0pi -e 's/\n([ \t]*)buildTypes \{/\n$1signingConfigs {\n$1    create("release") {\n$1        val ks = System.getenv("CM_KEYSTORE_PATH")\n$1        if (ks != null) {\n$1            storeFile = file(ks)\n$1            storePassword = System.getenv("CM_KEYSTORE_PASSWORD")\n$1            keyAlias = System.getenv("CM_KEY_ALIAS")\n$1            keyPassword = System.getenv("CM_KEY_PASSWORD")\n$1        }\n$1    }\n$1}\n$1buildTypes {/' "$G"
  perl -0pi -e 's/signingConfig = signingConfigs\.getByName\("debug"\)/signingConfig = if (System.getenv("CM_KEYSTORE_PATH") != null) signingConfigs.getByName("release") else signingConfigs.getByName("debug")/' "$G"
fi

# Android: tonos de KLK para las notificaciones (res/raw), protegidos del recorte de recursos
RAW=android/app/src/main/res/raw
mkdir -p "$RAW"
for f in assets/sounds/*.wav; do cp "$f" "$RAW/klk_$(basename "$f")"; done
printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' \
  '<resources xmlns:tools="http://schemas.android.com/tools" tools:keep="@raw/klk_*" />' > "$RAW/keep.xml"

# Android: Face ID/huella (local_auth) necesita FlutterFragmentActivity
for act in $(find android/app/src/main -name "MainActivity.kt" -o -name "MainActivity.java"); do
  sed -i.bak 's/io\.flutter\.embedding\.android\.FlutterActivity/io.flutter.embedding.android.FlutterFragmentActivity/; s/: FlutterActivity()/: FlutterFragmentActivity()/; s/extends FlutterActivity/extends FlutterFragmentActivity/' "$act"
done

# iOS: que las notificaciones se puedan mostrar (flutter_local_notifications)
APPDELEGATE=ios/Runner/AppDelegate.swift
if [ -f "$APPDELEGATE" ] && ! grep -q "UNUserNotificationCenter" "$APPDELEGATE"; then
  perl -0pi -e 's/import UIKit\n/import UIKit\nimport UserNotifications\n/' "$APPDELEGATE"
  perl -0pi -e 's/(\n(\s*)GeneratedPluginRegistrant\.register\([^\n]*\)\n)/$1$2UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate\n/' "$APPDELEGATE"
fi

# Android: las notificaciones locales necesitan "desugaring" de Java
for g in android/app/build.gradle.kts; do
  if [ -f "$g" ] && ! grep -q "CoreLibraryDesugaring" "$g"; then
    perl -0pi -e 's/compileOptions \{/compileOptions {\n        isCoreLibraryDesugaringEnabled = true/' "$g"
    printf '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n' >> "$g"
  fi
done
for g in android/app/build.gradle; do
  if [ -f "$g" ] && ! grep -q "coreLibraryDesugaring" "$g"; then
    perl -0pi -e 's/compileOptions \{/compileOptions {\n        coreLibraryDesugaringEnabled true/' "$g"
    printf "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n" >> "$g"
  fi
done

find ios android -name "*.bak" -delete
echo "Carpetas nativas listas (bundle: $BUNDLE_ID)"
