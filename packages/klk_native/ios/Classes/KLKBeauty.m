#import "KLKBeauty.h"
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#import <Metal/Metal.h>

#if __has_include(<flutter_webrtc/FlutterWebRTCPlugin.h>)
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/LocalVideoTrack.h>
#define KLK_HAS_WEBRTC 1
#elif __has_include("FlutterWebRTCPlugin.h")
#import "FlutterWebRTCPlugin.h"
#import "LocalVideoTrack.h"
#define KLK_HAS_WEBRTC 1
#else
#define KLK_HAS_WEBRTC 0
#endif

#if KLK_HAS_WEBRTC

/// Procesa cada fotograma de la cámara: busca la cara cada pocos fotogramas y
/// aplica el suavizado solo sobre ella (con bordes difuminados para que no se note).
@interface KLKBeautyProcessor : NSObject <ExternalVideoProcessingDelegate>
@property(atomic) double level;
@end

@implementation KLKBeautyProcessor {
  CIContext *_ctx;
  CVPixelBufferPoolRef _pool;
  int _poolW, _poolH;
  NSUInteger _count;
  NSArray<NSValue *> *_faces;  // rectángulos normalizados (imagen derecha, origen abajo-izq.)
  NSUInteger _facesAge;
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

static CGImagePropertyOrientation KLKOrientation(RTCVideoRotation r) {
  switch (r) {
    case RTCVideoRotation_90: return kCGImagePropertyOrientationRight;
    case RTCVideoRotation_180: return kCGImagePropertyOrientationDown;
    case RTCVideoRotation_270: return kCGImagePropertyOrientationLeft;
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

- (RTCVideoFrame *)onFrame:(RTCVideoFrame *)frame {
  double level = self.level;
  if (level <= 0.01) return frame;
  if (![frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) return frame;
  CVPixelBufferRef src = ((RTCCVPixelBuffer *)frame.buffer).pixelBuffer;
  if (!src) return frame;
  @autoreleasepool {
    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    CGImagePropertyOrientation o = KLKOrientation(frame.rotation);
    CGAffineTransform t = [img imageTransformForCGOrientation:o];
    CIImage *up = [img imageByApplyingTransform:t];
    CGRect ext = up.extent;

    // La cara se busca cada 5 fotogramas (Vision es lo que más batería gasta).
    if (_count++ % 5 == 0) {
      CIImage *small = [up imageByApplyingTransform:CGAffineTransformMakeScale(0.5, 0.5)];
      [self detectFacesIn:small];
    } else if (++_facesAge > 45) {
      _faces = @[];
    }

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
    CIImage *smooth = [blur imageByApplyingFilter:@"CIBlendWithMask"
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

    // Vuelve a la orientación original del sensor (la rotación viaja aparte).
    CIImage *back = [[smooth imageByApplyingTransform:CGAffineTransformInvert(t)] imageByCroppingToRect:img.extent];
    int w = (int)CVPixelBufferGetWidth(src), h = (int)CVPixelBufferGetHeight(src);
    CVPixelBufferRef out = [self newBufferW:w h:h];
    if (!out) return frame;
    back = [back imageByApplyingTransform:CGAffineTransformMakeTranslation(-back.extent.origin.x, -back.extent.origin.y)];
    [_ctx render:back toCVPixelBuffer:out bounds:CGRectMake(0, 0, w, h) colorSpace:nil];
    RTCCVPixelBuffer *rb = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:out];
    CVPixelBufferRelease(out);
    return [[RTCVideoFrame alloc] initWithBuffer:rb rotation:frame.rotation timeStampNs:frame.timeStampNs];
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

+ (BOOL)setTrack:(NSString *)trackId level:(double)level {
#if KLK_HAS_WEBRTC
  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  id track = plugin.localTracks[trackId];
  if (![track isKindOfClass:[LocalVideoTrack class]]) return NO;
  @synchronized(KLKProcs()) {
    KLKBeautyProcessor *p = KLKProcs()[trackId];
    if (!p) {
      p = [[KLKBeautyProcessor alloc] init];
      KLKProcs()[trackId] = p;
      [(LocalVideoTrack *)track addProcessing:p];
    }
    p.level = MAX(0.0, MIN(1.0, level));
  }
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
    id track = [FlutterWebRTCPlugin sharedSingleton].localTracks[trackId];
    if ([track isKindOfClass:[LocalVideoTrack class]]) [(LocalVideoTrack *)track removeProcessing:p];
    [KLKProcs() removeObjectForKey:trackId];
  }
#endif
}

@end
