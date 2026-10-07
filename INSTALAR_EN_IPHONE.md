# Cómo instalar KLK en tu iPhone (sin Mac)

Apple solo deja instalar apps de prueba a través de **TestFlight**. El proyecto ya está preparado para que **Codemagic** lo compile en sus Mac en la nube y lo suba a TestFlight.

Tiempo aproximado: 1 hora de configuración, más 1 o 2 días de espera la primera vez, mientras Apple aprueba tu cuenta de desarrollador.

## Lo que necesitas

| Cuenta | Coste | Para qué |
|---|---|---|
| Apple Developer | 99 USD/año | Firmar la app y usar TestFlight. Imprescindible en iPhone |
| GitHub | Gratis | Guardar el código; Codemagic lo lee de ahí |
| Codemagic | Gratis (500 min/mes) | Compilar la app para iPhone sin tener Mac |

## Paso 1. Cuenta de Apple Developer

1. Entra en developer.apple.com/programs/enroll con tu Apple ID y date de alta como **persona física**. Paga los 99 USD.
2. Espera el correo de aprobación (normalmente 24–48 h).

## Paso 2. Registrar la app en Apple

1. En developer.apple.com → *Certificates, IDs & Profiles* → **Identifiers** → **+** → *App IDs* → *App*.
   - Descripción: `KLK`
   - Bundle ID (Explicit): `com.klkapp.klk`
2. En appstoreconnect.apple.com → **Apps** → **+** → *Nueva app*:
   - Plataforma: iOS
   - Nombre: el nombre "KLK" seguramente ya esté ocupado en el App Store. Prueba **"KLK – Tu gente"** o similar. El icono seguirá diciendo KLK.
   - Idioma principal: Español
   - Bundle ID: `com.klkapp.klk`
   - SKU: `klk001`
3. Dentro de la app, en *Información de la app*, apunta el número **Apple ID** (unas 10 cifras).
4. **Clave de API:** *Usuarios y acceso* → *Integraciones* → *App Store Connect API* → **+**. Ponle de nombre "Codemagic" y el acceso *App Manager*. Descarga el archivo `.p8` (solo se puede descargar una vez) y apunta el **Issuer ID** y el **Key ID**.

## Paso 3. Subir el código a GitHub

1. Crea una cuenta gratis en github.com.
2. **New repository** → nombre `klk` → *Private* → *Create*.
3. En el repositorio vacío: *uploading an existing file*. Arrastra **todo el contenido** de la carpeta `klk` (no la carpeta, sino lo que hay dentro) → *Commit changes*.
4. Edita `codemagic.yaml` desde GitHub (el lápiz ✏️):
   - `APP_STORE_APPLE_ID`: el número del paso 2.3.
   - `KLK_SERVER`: la dirección de tu servidor (paso 6). Déjalo vacío para la versión demo.

## Paso 4. Configurar Codemagic

1. Entra en codemagic.io → *Sign up with GitHub* → **Add application** → elige el repositorio `klk` → tipo *Flutter App (via codemagic.yaml)*.
2. **Clave de Apple:** *Teams* → *Personal Account* → *Integrations* → *Developer Portal* → *Manage keys* → **Add key**.
   - Nombre exacto: `KLK App Store Connect`
   - Issuer ID, Key ID y el archivo `.p8` del paso 2.4
3. **Certificado:** *Code signing identities* → *iOS certificates* → **Generate certificate** → tipo *Apple Distribution*, con la clave anterior.
4. **Perfil:** en *iOS provisioning profiles* → **Fetch profiles**. Si no aparece ninguno para `com.klkapp.klk`, créalo en developer.apple.com → *Profiles* → **+** → *App Store Connect* → App ID `com.klkapp.klk` → el certificado del paso anterior. Después vuelve a pulsar *Fetch profiles*.

## Paso 5. Compilar e instalar

1. En Codemagic → tu app → **Start new build** → workflow **KLK iOS → TestFlight**. Tarda unos 20–30 minutos.
2. Cuando termine, ve a App Store Connect → tu app → **TestFlight**:
   - Apple preguntará por el **cumplimiento de exportación**, porque KLK usa cifrado. Responde que sí usa cifrado y sigue las preguntas. Si vas a publicar en la tienda, conviene que lo confirme un asesor, porque puede requerir un informe anual a EE. UU.
   - En *Pruebas internas*, crea un grupo y **añádete como probador** con tu Apple ID.
3. En tu iPhone instala la app **TestFlight** del App Store. Te llegará la invitación al correo → **Instalar**. 🎉

Cada vez que cambies el código, lanza otra compilación y TestFlight te ofrecerá la actualización.

## Paso 6 (opcional). Poner el servidor en marcha

Sin servidor, la app funciona en **modo demo**: contactos de ejemplo y código 123456. Para chatear de verdad entre dos móviles:

1. Sube la carpeta `klk-server` a otro repositorio de GitHub, igual que en el paso 3.
2. En render.com → *New* → **Blueprint** → elige ese repositorio. Render crea el servidor y la base de datos gratis con `render.yaml`.
3. Copia la dirección que te da Render (p. ej. `https://klk-server.onrender.com`). Ponla en `KLK_SERVER` de `codemagic.yaml` y vuelve a compilar.
4. Mientras no configures Twilio, **los códigos SMS no se envían**: aparecen en *Logs* de Render. Para SMS reales, añade `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` y `TWILIO_FROM` en *Environment* de Render.

El plan gratuito de Render se duerme tras 15 minutos sin uso, así que el primer mensaje puede tardar unos 30 segundos. Su base de datos gratuita caduca a los 30 días. Sirve para probar, no para lanzar.

## ¿Y en Android?

El mismo `codemagic.yaml` tiene el workflow **KLK Android (APK)**. Genera un `.apk` que se instala directamente, sin cuenta de pago.
