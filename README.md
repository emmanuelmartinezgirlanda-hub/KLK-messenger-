# KLK 🇩🇴

**Tu gente, donde tú estés.**

App de mensajería privada para los dominicanos del mundo entero. Está hecha en Flutter para iOS y Android y se conecta a `klk-server`.

👉 **Para instalarla en tu iPhone:** lee [INSTALAR_EN_IPHONE.md](INSTALAR_EN_IPHONE.md).

## Qué hace esta versión (0.1)

- **Registro por SMS** con prefijos de la diáspora (RD, EE. UU., Puerto Rico, España, Italia, Irlanda…).
- **Chats 1 a 1 cifrados de punta a punta.** Los mensajes se cifran en el móvil; el servidor solo ve sobres cerrados.
- **Estados del mensaje:** enviado ✓, entregado ✓✓ y leído ✓✓ en color.
- **"escribiendo…"** en tiempo real.
- **Mensajes programados:** el servidor los entrega a su hora aunque tu móvil esté apagado.
- **Privacidad:** ocultar la última conexión, las confirmaciones de lectura (con reciprocidad), "escribiendo…" y "grabando…".
- **Temas:** Noche Caribeña, Quisqueya y Apagón, con color de burbujas, redondeo y fuente a tu gusto.
- **"Hora de allá":** muestra la hora local de tu contacto según su número.
- **Seguridad local:**
  - Base de datos cifrada con SQLCipher; la clave vive en Keychain o Keystore.
  - Aviso si cambia la clave de seguridad de un contacto.
  - Botón de pánico.
- **Modo demo:** si no hay servidor configurado, la app funciona con contactos de ejemplo (código 123456).
- **Comunidades por ciudad:** por ahora es una vista previa con datos de ejemplo.

## Estructura

```
lib/
├── main.dart                         arranque y elección de pantalla
├── core/
│   ├── config.dart                   servidor (--dart-define=KLK_SERVER=…)
│   ├── crypto/                       CryptoEngine + cifrado provisional (ver README dentro)
│   ├── database/local_db.dart        SQLCipher: chats y mensajes
│   ├── network/                      API HTTP + PresenceGate
│   ├── security/secure_store.dart    Keychain/Keystore, sesión, pánico
│   └── util/phone.dart               países, E.164, "hora de allá"
└── features/
    ├── messaging/                    AppController (WebSocket, envío, recibos, demo)
    ├── onboarding/                   bienvenida + código SMS
    ├── home/                         pestañas Chats · Comunidades · Ajustes
    ├── chat/                         lista, conversación, burbujas, nuevo chat
    ├── communities/  settings/  privacy/  theming/
tool/prepare_native.sh                genera ios/ y android/ y les pone nombre e icono
codemagic.yaml                        compilación en la nube (TestFlight y APK)
```

## Desarrollo en un ordenador propio

```bash
bash tool/prepare_native.sh
flutter test
flutter run --dart-define=KLK_SERVER=http://192.168.1.50:8080   # o sin define: modo demo
```

## Antes de lanzar al público

- [ ] Sustituir el cifrado provisional por **vodozemac** (`lib/core/crypto/README.md`) y hacer una auditoría externa.
- [ ] **Notificaciones push** (APNs/FCM). Ahora los mensajes llegan al abrir la app.
- [ ] Mover a la cola cifrada de la BD los mensajes pendientes de enviar sin conexión (hoy viven en memoria).
- [ ] Fotos y videos sin compresión, grupos y comunidades reales.
- [ ] Política de privacidad y términos, que el App Store exige.
