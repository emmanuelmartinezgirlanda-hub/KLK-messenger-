#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Modo belleza de las videollamadas: detecta la cara (Vision) y suaviza la piel,
/// da luz y un tono más favorecedor (Core Image) ANTES de enviar el vídeo, así que
/// la otra persona ya te ve con el efecto. 0 = apagado, 1 = máximo.
@interface KLKBeauty : NSObject

/// Activa o ajusta el modo belleza en una pista de vídeo local de flutter_webrtc.
/// Devuelve NO si no encuentra la pista (por ejemplo, la cámara aún no está lista).
+ (BOOL)setTrack:(NSString *)trackId level:(double)level;

/// Pone (o quita, con nil) una cara de animal (emoji) encima de la cara.
+ (BOOL)setTrack:(NSString *)trackId mask:(nullable NSString *)mask;

/// Mejora de imagen (más luz y nitidez).
+ (BOOL)setTrack:(NSString *)trackId enhance:(BOOL)on;

/// Quita el procesado de una pista (al colgar).
+ (void)removeTrack:(NSString *)trackId;

@end

NS_ASSUME_NONNULL_END
