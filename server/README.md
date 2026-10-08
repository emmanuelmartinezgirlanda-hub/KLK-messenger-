# KLK Server 🇩🇴

Servidor de enrutado de mensajes de **KLK**. Su único trabajo es mover sobres cifrados de un móvil a otro. **Nunca ve el contenido**: el cifrado y el descifrado ocurren en los teléfonos con el protocolo Signal (X3DH + Double Ratchet).

## Qué guarda el servidor (y qué no)

| Guarda | No guarda |
|---|---|
| Número de teléfono y su ID de cuenta | Texto, fotos ni audios en claro |
| Claves **públicas** de cada dispositivo | Claves privadas |
| Sobres cifrados **hasta que se entregan** (después se borran) | Historial de chats |
| Hash SHA-256 del token de sesión | El token en sí |
| | Última conexión, "escribiendo..." ni confirmaciones de lectura |

La última conexión, los "escribiendo..." y las confirmaciones de lectura viajan **cifrados como mensajes normales**. El servidor ni siquiera puede distinguirlos. Así, la privacidad que el usuario configura en la app (`PresenceGate`) no depende de confiar en el servidor.

## Arrancar

```bash
# Con Docker (Postgres + servidor)
docker compose up --build

# O en local
go mod tidy                     # la primera vez: genera go.sum
go run ./cmd/klk-server          # sin DATABASE_URL usa memoria (solo desarrollo)
DATABASE_URL=postgres://klk:klk@localhost:5432/klk go run ./cmd/klk-server
```

Variables de entorno:

| Variable | Para qué |
|---|---|
| `DATABASE_URL` | Postgres. Si está vacía se usa memoria (solo desarrollo) |
| `PORT` / `KLK_ADDR` | Puerto de escucha (por defecto 8080) |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM` | SMS reales. Sin ellas, los códigos aparecen en el log |
| `KLK_TRUST_PROXY=1` | Detrás de Render, Cloudflare, etc.: limita por la IP real del usuario |

**Despliegue gratis para pruebas:** sube este repositorio a GitHub y en render.com usa *New → Blueprint*. El archivo `render.yaml` crea el servidor y la base de datos.

## Tests

```bash
go test -race ./...                                              # almacén en memoria
KLK_TEST_DATABASE_URL=postgres://... go test -race -p 1 ./...    # contra Postgres real
```

Los tests de extremo a extremo cubren estos casos:
- Registro por SMS, publicación de claves, búsqueda por número y consumo de prekeys.
- Entrega en vivo, entrega diferida a un móvil desconectado y borrado tras el `ack`.
- Rechazo cuando la lista de dispositivos no coincide.
- Los mensajes efímeros ("escribiendo...") no se guardan.
- Los mensajes programados no llegan antes de su hora.
- Re-registrar el número invalida el token anterior.
- Un código OTP se bloquea tras 5 intentos fallidos.

## API HTTP

Todas las rutas autenticadas usan `Authorization: Bearer <token>`. Los bytes van en base64.

| Método y ruta | Auth | Cuerpo / respuesta |
|---|---|---|
| `POST /v1/verification/request` | — | `{"phone":"+18095551234"}` → 204. Máx. 1 SMS/min por número |
| `POST /v1/verification/verify` | — | `{"phone","code","deviceName","registrationId","identityKey"}` → `{"accountId","deviceId","token"}` |
| `PUT /v1/keys` | ✔ | `{"signedPreKey":{"keyId","publicKey","signature"},"preKeys":[{"keyId","publicKey"}]}` → 204 |
| `GET /v1/keys/count` | ✔ | `{"count":N}`. Si baja de ~20, el cliente sube más prekeys |
| `GET /v1/keys/{accountId}` | ✔ | `{"devices":[bundle…]}`. Consume una prekey por dispositivo |
| `POST /v1/accounts/lookup` | ✔ | `{"phone"}` → `{"accountId"}` |
| `GET /v1/ws` | ✔ | WebSocket (abajo) |
| `GET /healthz` | — | `ok` |

## Protocolo WebSocket

```jsonc
// Enviar (el cliente cifra una copia por cada dispositivo del destinatario)
{"t":"send","ref":"c-123","to":"<accountId>",
 "messages":[{"device":1,"type":3,"content":"<base64>"}],
 "deliverAt":"2026-12-24T23:59:00Z",   // opcional → mensaje programado
 "ephemeral":true}                      // opcional → "escribiendo...", no se guarda

// Confirmar recepción (el servidor lo borra)
{"t":"ack","id":"<envelopeId>"}

// Lo que recibe el cliente
{"t":"msg","id","from","fromDevice","type","content","ts","ephemeral"}
{"t":"sent","ref":"c-123","ts","scheduled":true}
{"t":"synced"}   // ya se entregó toda la cola pendiente
{"t":"error","ref","code":"mismatched_devices","devices":[1,2]}
```

**Reglas para el cliente:**
- Elimina duplicados por `id` (un mensaje puede llegar dos veces si la conexión se corta antes del `ack`).
- Si recibe `mismatched_devices`, vuelve a pedir `/v1/keys/{id}` y reenvía.
- Si el mensaje es programado, el texto se cifra **al crearlo**. El servidor solo guarda el sobre cerrado hasta la hora fijada.

## Estructura

```
cmd/klk-server/        arranque, configuración, apagado ordenado
internal/auth/         OTP por SMS (Twilio o log), tokens, validación E.164
internal/api/          rutas HTTP, límites por IP, tests de extremo a extremo
internal/relay/        hub WebSocket, entrega, programador de mensajes
internal/store/        interfaz + memoria + Postgres (migraciones embebidas)
```

## ⚠️ Licencia de libsignal

La biblioteca oficial **libsignal tiene licencia AGPL-3.0**. Si la usas en la app de KLK, tendrás que publicar el código fuente de la app bajo esa misma licencia. Hay dos caminos:

1. **Aceptar AGPL** y hacer KLK de código abierto, como hace Signal. Esto también genera confianza en una app de privacidad.
2. Usar **vodozemac** (Rust, licencia Apache-2.0). Es la implementación de Olm/Megolm de Matrix, también con Double Ratchet y auditada. El servidor apenas cambiaría.

Conviene decidirlo **antes** de escribir el cliente cripto. Si hay dudas, consulta a un abogado.

## Pendiente antes de producción

- [ ] **Protección antifraude de SMS** (Twilio Verify o límites por país). El envío por Twilio ya está integrado.
- [ ] **Push** con APNs/FCM (`relay.Pusher`). La notificación no debe llevar contenido.
- [ ] **OTP y límites en Redis** para poder correr varias instancias. Hoy están en memoria y el mapa de límites por IP no se purga.
- [ ] **Hub distribuido** (Redis pub/sub o NATS) para entregar entre instancias.
- [ ] **Dispositivos vinculados** (tablet o escritorio). Hoy solo hay dispositivo principal.
- [ ] **Medios:** subida a S3/R2 con URLs firmadas. El archivo se cifra en el móvil y solo viaja la clave dentro del mensaje.
- [ ] **Descubrimiento privado de contactos.** `lookup` revela si un número usa KLK. Mitigación avanzada: enclaves seguros (como Signal) o límites estrictos.
- [ ] **TLS** delante (Caddy o Cloudflare), con métricas y alertas.
- [ ] **Caducidad de sobres no entregados** (p. ej. 30 días).
