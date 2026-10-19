# KLK messenger en Google Play

## Datos de la app
- **Nombre:** KLK messenger
- **Paquete:** com.klkapp.klk
- **Hecha con:** Flutter (Android + iPhone + Windows), servidor propio en Go
- **Categoría:** Comunicación
- **Gratis**, sin anuncios
- **Correo de contacto:** klkmessenger.rd@gmail.com
- **Web:** https://klkmessenger.com
- **Política de privacidad:** https://klk-server.onrender.com/privacidad
- **Borrar cuenta (enlace web):** https://klkmessenger.com/borrar-cuenta

## Ficha de la tienda

**Descripción breve (80 caracteres máx.):**
Chats, audios y stickers con tu gente. La app de mensajes de los dominicanos.

**Descripción completa:**
KLK messenger es la app de mensajes de los dominicanos. Habla con tu familia y tus panas en RD, Nueva York, España o donde estén, con la tranquilidad de que tus conversaciones son solo tuyas.

PRIVADA DE VERDAD
• Cifrado de punta a punta en todos los chats, audios, fotos y llamadas: solo tú y la persona con quien hablas pueden leerlos. Ni KLK puede verlos.
• PIN de seguridad: nadie entra con tu número sin tu PIN.
• Bloqueo con huella, chats ocultos y botón de pánico para borrarlo todo en un segundo.
• Mensajes temporales y fotos para ver una vez.
• Sin publicidad. No vendemos tus datos.

TODO LO QUE NECESITAS
• Mensajes, notas de voz (a 1,5× y 2×), fotos, vídeos y documentos.
• Llamadas y videollamadas cifradas.
• Crea tus propios stickers con tus fotos, y usa los nuestros: ¡Tamo activo!
• Grupos con encuestas y menciones con @.
• Comunidades de dominicanos por país.
• Pelota y noticias de RD a un toque: pelota invernal, Grandes Ligas y periódicos dominicanos.
• Mensajes programados: escribe hoy el «feliz cumpleaños» y que llegue a las 12.
• Traductor dentro del móvil, sin enviar tus mensajes a ningún servidor.
• Estados que desaparecen a las 24 horas.
• Comparte tu contacto con un código QR.
• Copia de seguridad cifrada con contraseña.
• Temas y fondos con los colores de la bandera.

MUY PRONTO
• Envío de dinero a República Dominicana desde el chat.
• Recargas a Claro, Altice y Viva.

HECHA PARA NOSOTROS
Con el sabor de nuestra tierra: ¡Klk, mi gente! 🇩🇴

## Gráficos (en esta carpeta)
- Icono 512 × 512: `icono-512.png`
- Imagen destacada 1024 × 500: `imagen-destacada-1024x500.png`
- Capturas de teléfono 1080 × 2160: `captura-1-chats.png`, `captura-2-audios-stickers.png`, `captura-3-grupos.png`, `captura-4-codigo-qr.png`

## Seguridad de los datos (formulario «Data safety»)
- **¿Recoge o comparte datos?** Sí.
- **¿Todos los datos van cifrados en tránsito?** Sí.
- **¿Pueden pedir que se borren sus datos?** Sí (en la app: Ajustes → Cuenta → Eliminar mi cuenta, o en https://klkmessenger.com/borrar-cuenta).

Datos recogidos (ninguno se comparte con terceros; los proveedores como Twilio o Render trabajan para KLK y no cuentan como «compartir»):

| Tipo de dato | ¿Se recoge? | ¿Obligatorio? | Para qué |
|---|---|---|---|
| Información personal → Número de teléfono | Sí | Obligatorio | Funcionamiento de la app, gestión de la cuenta, prevención de fraude y seguridad |
| Contactos | Sí, procesado de forma efímera (no se guarda) | Opcional | Funcionamiento de la app (ver qué contactos usan KLK) |
| Mensajes → Otros mensajes en la app | Sí, solo los que el usuario adjunta al denunciar | Opcional | Prevención de fraude, seguridad y cumplimiento |

No se declaran mensajes, fotos, vídeos, audios, archivos ni ubicación compartidos en los chats: van **cifrados de punta a punta** y Google indica que esos datos no cuentan como «recogidos».
No hay datos de pago (las recargas aún no están activas), ni identificadores de publicidad, ni analíticas.

## Clasificación de contenido
- Los usuarios pueden comunicarse entre sí: **Sí**.
- Los usuarios pueden compartir su ubicación con otros: **Sí** (solo si la envían en un chat).
- Violencia, sexo, drogas, apuestas: **No**.

## Público objetivo
- **13 años o más** (no está pensada para niños).

## Otras declaraciones
- **Anuncios:** No.
- **Acceso a la app:** hace falta iniciar sesión. Para la revisión: número **+1 202 555 0147** (o +1 202 555 0148) y el mismo código de revisión que se usó con Apple. No se envía SMS.
- **App de noticias:** No (solo enlaza a webs de periódicos).
- **Funciones financieras:** Ninguna por ahora.
- **Aplicación gubernamental / salud:** No.

## Firma y versión
- Se genera un **.aab firmado** con Codemagic (flujo «KLK Android → Google Play (.aab)»), apuntando a **Android 16 (API 36)**.
- La clave de subida se llama **klk_upload** y vive en Codemagic. Activa **Play App Signing** al subir la primera versión: así Google guarda la clave final de la app y, si algún día se pierde la de subida, se puede cambiar.
