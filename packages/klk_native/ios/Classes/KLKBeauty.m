#import "KLKBeauty.h"
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <Metal/Metal.h>

#import <objc/message.h>

// flutter_webrtc puede venir por CocoaPods o por Swift Package Manager, así que no lo
// enlazamos: buscamos sus clases (y las de WebRTC) en tiempo de ejecución.
#define KLK_HAS_WEBRTC 1

typedef id (*KLKInitBuf)(id, SEL, CVPixelBufferRef);
typedef id (*KLKInitFrame)(id, SEL, id, NSInteger, int64_t);
typedef void (*KLKAddProc)(id, SEL, id);

static NSInteger KLKInt(id obj, NSString *key) {
  @try { return [[obj valueForKey:key] integerValue]; } @catch (__unused id e) { return 0; }
}

#if KLK_HAS_WEBRTC

/// Procesa cada fotograma de la cámara: busca la cara cada pocos fotogramas y
/// aplica el suavizado solo sobre ella (con bordes difuminados para que no se note).
@interface KLKBeautyProcessor : NSObject
@property(atomic) double level;
/// Cara de animal (emoji) que tapa la cara, como en FaceTime. nil = sin máscara.
@property(atomic, copy, nullable) NSString *mask;
/// Mejora de imagen: más luz y nitidez (para sitios oscuros).
@property(atomic) BOOL enhance;
@end

@implementation KLKBeautyProcessor {
  CIContext *_ctx;
  CVPixelBufferPoolRef _pool;
  int _poolW, _poolH;
  NSUInteger _count;
  NSArray<NSValue *> *_faces;  // rectángulos normalizados (imagen derecha, origen abajo-izq.)
  NSUInteger _facesAge;
  NSString *_maskKey;
  CIImage *_maskImg;
  NSArray<NSValue *> *_maskRects; // posición suavizada de la máscara (para que no tiemble)
}

- (instancetype)init {
  if ((self = [super init])) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSDictionary *opts = @{kCIContextWorkingColorSpace : [NSNull null], kCIContextCacheIntermediates : @NO};
    _ctx = dev ? [CIContext contextWithMTLDevice:dev options:opts] : [CIContext contextWithOptions:opts];
    _faces = @[];
  }
  return self;
}

- (void)dealloc {
  if (_pool) CVPixelBufferPoolRelease(_pool);
}

static CGImagePropertyOrientation KLKOrientation(NSInteger r) {
  switch (r) {
    case 90: return kCGImagePropertyOrientationRight;
    case 180: return kCGImagePropertyOrientationDown;
    case 270: return kCGImagePropertyOrientationLeft;
    default: return kCGImagePropertyOrientationUp;
  }
}

- (CVPixelBufferRef)newBufferW:(int)w h:(int)h CF_RETURNS_RETAINED {
  if (!_pool || _poolW != w || _poolH != h) {
    if (_pool) CVPixelBufferPoolRelease(_pool);
    _pool = NULL;
    NSDictionary *attrs = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      (id)kCVPixelBufferWidthKey : @(w),
      (id)kCVPixelBufferHeightKey : @(h),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &_pool);
    _poolW = w;
    _poolH = h;
  }
  CVPixelBufferRef out = NULL;
  if (_pool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &out);
  return out;
}

- (void)detectFacesIn:(CIImage *)upright {
  VNDetectFaceRectanglesRequest *req = [[VNDetectFaceRectanglesRequest alloc] init];
  VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCIImage:upright options:@{}];
  NSError *err = nil;
  if (![h performRequests:@[ req ] error:&err]) return;
  NSMutableArray *f = [NSMutableArray array];
  for (VNFaceObservation *o in req.results) {
    if (o.confidence < 0.5) continue;
    [f addObject:[NSValue valueWithCGRect:o.boundingBox]];
  }
  _faces = f;
  _facesAge = 0;
  // Suaviza el movimiento de la máscara: mitad la posición anterior, mitad la nueva.
  if (_maskRects.count == f.count) {
    NSMutableArray *m = [NSMutableArray array];
    for (NSUInteger i = 0; i < f.count; i++) {
      CGRect a = [_maskRects[i] CGRectValue], b = [f[i] CGRectValue];
      [m addObject:[NSValue valueWithCGRect:CGRectMake((a.origin.x + b.origin.x) / 2, (a.origin.y + b.origin.y) / 2,
                                                       (a.size.width + b.size.width) / 2,
                                                       (a.size.height + b.size.height) / 2)]];
    }
    _maskRects = m;
  } else {
    _maskRects = f;
  }
}

/// El emoji de la máscara convertido en imagen (se hace una sola vez por emoji).
- (CIImage *)maskImage {
  NSString *m = self.mask;
  if (m.length == 0) return nil;
  if (![m isEqualToString:_maskKey]) {
    CGFloat side = 320;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    UIImage *ui = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
      NSDictionary *attrs = @{NSFontAttributeName : [UIFont systemFontOfSize:side * 0.8]};
      CGSize sz = [m sizeWithAttributes:attrs];
      [m drawAtPoint:CGPointMake((side - sz.width) / 2, (side - sz.height) / 2) withAttributes:attrs];
    }];
    _maskImg = ui.CGImage ? [CIImage imageWithCGImage:ui.CGImage] : nil;
    _maskKey = [m copy];
  }
  return _maskImg;
}

/// Pone el emoji encima de cada cara (un poco más grande que la cara).
- (CIImage *)applyMaskTo:(CIImage *)img ext:(CGRect)ext {
  CIImage *e = [self maskImage];
  if (!e || _maskRects.count == 0) return img;
  CIImage *out = img;
  for (NSValue *v in _maskRects) {
    CGRect n = v.CGRectValue;
    CGFloat w = n.size.width * ext.size.width, h = n.size.height * ext.size.height;
    CGFloat side = MAX(w, h) * 1.75;
    CGFloat cx = ext.origin.x + (n.origin.x + n.size.width / 2) * ext.size.width;
    CGFloat cy = ext.origin.y + (n.origin.y + n.size.height * 0.55) * ext.size.height;
    CGFloat k = side / e.extent.size.width;
    CGAffineTransform t = CGAffineTransformMakeScale(k, k);
    t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(cx - side / 2, cy - side / 2));
    out = [[e imageByApplyingTransform:t] imageByCompositingOverImage:out];
  }
  return [out imageByCroppingToRect:ext];
}

/// Máscara blanca sobre las caras (difuminada hacia fuera); negra en el resto.
- (CIImage *)maskFor:(CGRect)ext {
  CIImage *mask = nil;
  for (NSValue *v in _faces) {
    CGRect n = v.CGRectValue;
    CGFloat w = n.size.width * ext.size.width, h = n.size.height * ext.size.height;
    CGPoint c = CGPointMake(ext.origin.x + (n.origin.x + n.size.width / 2) * ext.size.width,
                            // un poco más abajo para cubrir mejillas y cuello
                            ext.origin.y + (n.origin.y + n.size.height * 0.42) * ext.size.height);
    CGFloat r = MAX(w, h);
    CIFilter *g = [CIFilter filterWithName:@"CIRadialGradient"];
    [g setValue:[CIVector vectorWithX:c.x Y:c.y] forKey:@"inputCenter"];
    [g setValue:@(r * 0.55) forKey:@"inputRadius0"];
    [g setValue:@(r * 0.95) forKey:@"inputRadius1"];
    [g setValue:[CIColor colorWithRed:1 green:1 blue:1] forKey:@"inputColor0"];
    [g setValue:[CIColor colorWithRed:0 green:0 blue:0] forKey:@"inputColor1"];
    CIImage *one = [g.outputImage imageByCroppingToRect:ext];
    mask = mask ? [one imageByApplyingFilter:@"CIMaximumCompositing" withInputParameters:@{kCIInputBackgroundImageKey : mask}] : one;
  }
  if (!mask) {
    // Sin cara detectada: suavizado muy suave en toda la imagen.
    mask = [[CIImage imageWithColor:[CIColor colorWithRed:0.3 green:0.3 blue:0.3]] imageByCroppingToRect:ext];
  }
  return mask;
}

/// Lo llama flutter_webrtc (VideoProcessingAdapter) con cada RTCVideoFrame de la cámara.
- (id)onFrame:(id)frame {
  double level = self.level;
  BOOL masked = self.mask.length > 0, enhance = self.enhance;
  if ((level <= 0.01 && !masked && !enhance) || !frame) return frame;
  Class cvBufClass = NSClassFromString(@"RTCCVPixelBuffer");
  Class frameClass = NSClassFromString(@"RTCVideoFrame");
  id buffer = [frame valueForKey:@"buffer"];
  if (!cvBufClass || !frameClass || ![buffer isKindOfClass:cvBufClass]) return frame;
  CVPixelBufferRef src = ((CVPixelBufferRef (*)(id, SEL))objc_msgSend)(buffer, NSSelectorFromString(@"pixelBuffer"));
  if (!src) return frame;
  NSInteger rotation = KLKInt(frame, @"rotation");
  int64_t ts = [[frame valueForKey:@"timeStampNs"] longLongValue];
  @autoreleasepool {
    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    CGImagePropertyOrientation o = KLKOrientation(rotation);
    CGAffineTransform t = [img imageTransformForCGOrientation:o];
    CIImage *up = [img imageByApplyingTransform:t];
    CGRect ext = up.extent;

    // La cara se busca cada 5 fotogramas (Vision es lo que más batería gasta);
    // con máscara, cada 2 para que siga bien la cara.
    if (_count++ % (masked ? 2 : 5) == 0) {
      CIImage *small = [up imageByApplyingTransform:CGAffineTransformMakeScale(0.5, 0.5)];
      [self detectFacesIn:small];
    } else if (++_facesAge > 45) {
      _faces = @[];
      _maskRects = @[];
    }

    CIImage *smooth = up;
    if (level > 0.01) {
    // 1) Piel suave: mezcla de la imagen con una versión desenfocada, solo en la cara.
    double radius = 3.0 + 9.0 * level;
    CIImage *blur = [[[up imageByClampingToExtent]
        imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey : @(radius)}]
        imageByCroppingToRect:ext];
    CIImage *mask = [[self maskFor:ext] imageByApplyingFilter:@"CIColorMatrix"
                                          withInputParameters:@{
                                            @"inputRVector" : [CIVector vectorWithX:0.85 * level Y:0 Z:0 W:0],
                                            @"inputGVector" : [CIVector vectorWithX:0 Y:0.85 * level Z:0 W:0],
                                            @"inputBVector" : [CIVector vectorWithX:0 Y:0 Z:0.85 * level W:0],
                                          }];
    smooth = [blur imageByApplyingFilter:@"CIBlendWithMask"
                              withInputParameters:@{kCIInputBackgroundImageKey : up, kCIInputMaskImageKey : mask}];
    // Devuelve un poco de detalle (ojos, cejas) para que no parezca de plástico.
    smooth = [smooth imageByApplyingFilter:@"CISharpenLuminance" withInputParameters:@{@"inputSharpness" : @(0.25)}];

    // 2) Luz y tono favorecedor.
    smooth = [smooth imageByApplyingFilter:@"CIHighlightShadowAdjust"
                       withInputParameters:@{@"inputShadowAmount" : @(0.35 * level), @"inputHighlightAmount" : @(1.0)}];
    smooth = [smooth imageByApplyingFilter:@"CIColorControls"
                       withInputParameters:@{
                         kCIInputBrightnessKey : @(0.025 * level),
                         kCIInputSaturationKey : @(1.0 + 0.08 * level),
                         kCIInputContrastKey : @(1.0 - 0.03 * level),
                       }];
    smooth = [smooth imageByApplyingFilter:@"CITemperatureAndTint"
                       withInputParameters:@{
                         @"inputNeutral" : [CIVector vectorWithX:6500 Y:0],
                         @"inputTargetNeutral" : [CIVector vectorWithX:6500 + 350 * level Y:0],
                       }];
    }

    // 3) Mejora de imagen: levanta las sombras, más luz y nitidez.
    if (enhance) {
      smooth = [smooth imageByApplyingFilter:@"CIHighlightShadowAdjust"
                         withInputParameters:@{@"inputShadowAmount" : @(0.7), @"inputHighlightAmount" : @(0.9)}];
      smooth = [smooth imageByApplyingFilter:@"CIColorControls"
                         withInputParameters:@{kCIInputBrightnessKey : @(0.04), kCIInputSaturationKey : @(1.1),
                                               kCIInputContrastKey : @(1.05)}];
      smooth = [smooth imageByApplyingFilter:@"CISharpenLuminance" withInputParameters:@{@"inputSharpness" : @(0.5)}];
      smooth = [smooth imageByCroppingToRect:ext];
    }

    // 4) Máscara de animal encima de la cara.
    if (masked) smooth = [self applyMaskTo:smooth ext:ext];

    // Vuelve a la orientación original del sensor (la rotación viaja aparte).
    CIImage *back = [[smooth imageByApplyingTransform:CGAffineTransformInvert(t)] imageByCroppingToRect:img.extent];
    int w = (int)CVPixelBufferGetWidth(src), h = (int)CVPixelBufferGetHeight(src);
    CVPixelBufferRef out = [self newBufferW:w h:h];
    if (!out) return frame;
    back = [back imageByApplyingTransform:CGAffineTransformMakeTranslation(-back.extent.origin.x, -back.extent.origin.y)];
    [_ctx render:back toCVPixelBuffer:out bounds:CGRectMake(0, 0, w, h) colorSpace:nil];
    id rb = ((KLKInitBuf)objc_msgSend)([cvBufClass alloc], NSSelectorFromString(@"initWithPixelBuffer:"), out);
    CVPixelBufferRelease(out);
    if (!rb) return frame;
    id nf = ((KLKInitFrame)objc_msgSend)([frameClass alloc], NSSelectorFromString(@"initWithBuffer:rotation:timeStampNs:"), rb, rotation, ts);
    return nf ?: frame;
  }
}

@end

static NSMutableDictionary<NSString *, KLKBeautyProcessor *> *KLKProcs(void) {
  static NSMutableDictionary *d;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
  return d;
}

#endif

@implementation KLKBeauty

+ (nullable id)localTrack:(NSString *)trackId {
  Class plugin = NSClassFromString(@"FlutterWebRTCPlugin");
  SEL shared = NSSelectorFromString(@"sharedSingleton");
  if (!plugin || ![plugin respondsToSelector:shared]) return nil;
  id inst = ((id (*)(id, SEL))objc_msgSend)(plugin, shared);
  if (!inst) return nil;
  @try {
    NSDictionary *tracks = [inst valueForKey:@"localTracks"];
    return [tracks isKindOfClass:[NSDictionary class]] ? tracks[trackId] : nil;
  } @catch (__unused id e) {
    return nil;
  }
}

#if KLK_HAS_WEBRTC
+ (nullable KLKBeautyProcessor *)processorFor:(NSString *)trackId {
  id track = [self localTrack:trackId];
  if (!track || ![track respondsToSelector:NSSelectorFromString(@"addProcessing:")]) return nil;
  @synchronized(KLKProcs()) {
    KLKBeautyProcessor *p = KLKProcs()[trackId];
    if (!p) {
      p = [[KLKBeautyProcessor alloc] init];
      KLKProcs()[trackId] = p;
      ((KLKAddProc)objc_msgSend)(track, NSSelectorFromString(@"addProcessing:"), p);
    }
    return p;
  }
}
#endif

+ (BOOL)setTrack:(NSString *)trackId level:(double)level {
#if KLK_HAS_WEBRTC
  KLKBeautyProcessor *p = [self processorFor:trackId];
  if (!p) return NO;
  p.level = MAX(0.0, MIN(1.0, level));
  return YES;
#else
  return NO;
#endif
}

+ (BOOL)setTrack:(NSString *)trackId mask:(nullable NSString *)mask {
#if KLK_HAS_WEBRTC
  KLKBeautyProcessor *p = [self processorFor:trackId];
  if (!p) return NO;
  p.mask = mask.length > 0 ? mask : nil;
  return YES;
#else
  return NO;
#endif
}

+ (BOOL)setTrack:(NSString *)trackId enhance:(BOOL)on {
#if KLK_HAS_WEBRTC
  KLKBeautyProcessor *p = [self processorFor:trackId];
  if (!p) return NO;
  p.enhance = on;
  return YES;
#else
  return NO;
#endif
}

+ (void)removeTrack:(NSString *)trackId {
#if KLK_HAS_WEBRTC
  @synchronized(KLKProcs()) {
    KLKBeautyProcessor *p = KLKProcs()[trackId];
    if (!p) return;
    p.level = 0;
    p.mask = nil;
    p.enhance = NO;
    id track = [self localTrack:trackId];
    if ([track respondsToSelector:NSSelectorFromString(@"removeProcessing:")])
      ((KLKAddProc)objc_msgSend)(track, NSSelectorFromString(@"removeProcessing:"), p);
    [KLKProcs() removeObjectForKey:trackId];
  }
#endif
}

@end
