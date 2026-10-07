# Cifrado en KLK

La app usa la interfaz `CryptoEngine`. Hoy la implementa `ProvisionalCrypto` ("KLK-v0"), que está escrito en Dart puro con el paquete `cryptography`. Funciona así:
- X25519 de identidad más una clave efímera por mensaje.
- La clave se deriva con HKDF-SHA256.
- El mensaje se cifra con AES-256-GCM.

**No es apto para lanzar al público.** No tiene Double Ratchet: si alguien robara la clave de identidad de un móvil, podría descifrar los mensajes antiguos de ese móvil que hubiera capturado. Además, no se ha auditado.

## Plan para producción: vodozemac

1. Crear un crate Rust con `vodozemac` (Olm, Apache-2.0) y exponerlo con `flutter_rust_bridge`.
2. Implementar `VodozemacCrypto implements CryptoEngine`:
   - Identidad: la clave Curve25519 de la cuenta Olm.
   - `signedPreKey()`: una clave de un solo uso firmada con la clave Ed25519 de Olm.
   - Las sesiones Olm se guardan cifradas en la BD SQLCipher.
3. El servidor no cambia: los sobres siguen siendo bytes opacos.
4. Auditoría de seguridad externa antes del lanzamiento.
