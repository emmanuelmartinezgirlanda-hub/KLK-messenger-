import AVFoundation
import CoreImage
import Flutter
import Speech
import UIKit
import UserNotifications
import Vision

/// Funciones nativas de KLK:
/// - "transcribe": pasa una nota de voz a texto SIN enviarla a ningún servidor
///   (requiresOnDeviceRecognition). Si el iPhone no puede hacerlo en el propio
///   móvil, devuelve un error en vez de mandar el audio a Apple.
/// - "klk/screenshots": avisa cuando el usuario hace una captura de pantalla.
public class KlkNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observer: NSObjectProtocol?
  // Se guardan para que no se liberen mientras transcriben.
  private var recognizer: SFSpeechRecognizer?
  private var task: SFSpeechRecognitionTask?
  // Esperando el token de avisos push de Apple.
  private var pushResult: FlutterResult?
  // Subtítulos de llamada (voz a texto en directo, dentro del iPhone).
  let captions = LiveCaptions()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = KlkNativePlugin()
    let channel = FlutterMethodChannel(name: "klk/native", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    let events = FlutterEventChannel(name: "klk/screenshots", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    let caps = FlutterEventChannel(name: "klk/captions", binaryMessenger: registrar.messenger())
    caps.setStreamHandler(instance.captions)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if PlusStore.handle(call, result: result) { return }
    switch call.method {
    case "transcribe":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "Falta el archivo", details: nil))
        return
      }
      transcribe(path: path, locale: (args["locale"] as? String) ?? "es-ES", result: result)
    case "liftSubject":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "Falta la foto", details: nil))
        return
      }
      liftSubject(path: path, result: result)
    case "compressVideo":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "Falta el vídeo", details: nil))
        return
      }
      compressVideo(path: path, result: result)
    case "registerPush":
      registerPush(result: result)
    case "startLiveCaptions":
      let locale = ((call.arguments as? [String: Any])?["locale"] as? String) ?? "es-US"
      captions.start(locale: locale, result: result)
    case "stopLiveCaptions":
      captions.stop()
      result(nil)
    case "isTestFlight":
      // Las versiones de TestFlight llevan un recibo de "sandbox".
      let r = Bundle.main.appStoreReceiptURL?.lastPathComponent ?? ""
      result(r == "sandboxReceipt")
    case "getAppIcon":
      result(UIApplication.shared.alternateIconName)
    case "setAppIcon":
      let name = (call.arguments as? [String: Any])?["name"] as? String
      guard UIApplication.shared.supportsAlternateIcons else {
        result(FlutterError(code: "unsupported", message: "Este iPhone no permite cambiar el icono", details: nil))
        return
      }
      UIApplication.shared.setAlternateIconName(name) { error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "failed", message: "No se pudo cambiar el icono: \(error.localizedDescription)", details: nil))
          } else {
            result(nil)
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func fail(_ result: @escaping FlutterResult, _ code: String, _ message: String) {
    DispatchQueue.main.async { result(FlutterError(code: code, message: message, details: nil)) }
  }

  private func transcribe(path: String, locale: String, result: @escaping FlutterResult) {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else {
          self.fail(result, "denied", "KLK no tiene permiso de reconocimiento de voz. Actívalo en Ajustes del iPhone → KLK.")
          return
        }
        let candidates = [locale, "es-US", "es-MX", "es-ES"]
        var chosen: SFSpeechRecognizer?
        for id in candidates {
          if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable, r.supportsOnDeviceRecognition {
            chosen = r
            break
          }
        }
        guard let rec = chosen else {
          self.fail(result, "no_on_device", "Este iPhone no puede pasar audios a texto sin internet. Por privacidad, KLK no envía tus audios fuera del móvil.")
          return
        }
        self.task?.cancel()
        self.recognizer = rec
        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(iOS 16, *) { request.addsPunctuation = true }
        var done = false
        self.task = rec.recognitionTask(with: request) { res, error in
          if done { return }
          if let error = error {
            done = true
            self.fail(result, "failed", "No se pudo pasar a texto: \(error.localizedDescription)")
            return
          }
          if let res = res, res.isFinal {
            done = true
            let text = res.bestTranscription.formattedString
            DispatchQueue.main.async { result(text) }
          }
        }
      }
    }
  }

  // ---------- Comprimir vídeo (estados largos) ----------

  /// Reduce el vídeo para que quepa en el servidor (máx. 64 MB). Prueba de mejor
  /// a peor calidad y se queda con la primera que, según el iPhone, pesará menos
  /// de ~45 MB (con margen). Así un vídeo corto sale nítido y uno largo sale más ligero.
  private func compressVideo(path: String, result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let limit: Int64 = 45 * 1024 * 1024
    let candidates = [
      AVAssetExportPreset1280x720,
      AVAssetExportPreset960x540,
      AVAssetExportPreset640x480,
      AVAssetExportPresetMediumQuality,
      AVAssetExportPresetLowQuality,
    ]
    let compatible = Set(AVAssetExportSession.exportPresets(compatibleWith: asset))
    var chosen: AVAssetExportSession?
    for preset in candidates where compatible.contains(preset) {
      guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
      export.outputFileType = .mp4
      export.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
      let estimate = export.estimatedOutputFileLength
      chosen = export
      if estimate > 0 && estimate <= limit { break }
    }
    guard let export = chosen else {
      fail(result, "no_export", "No se pudo preparar el vídeo")
      return
    }
    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("klk_\(UUID().uuidString).mp4")
    export.outputURL = out
    export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true
    export.exportAsynchronously {
      if export.status == .completed {
        DispatchQueue.main.async { result(out.path) }
      } else {
        let why = export.error?.localizedDescription ?? "error desconocido"
        self.fail(result, "failed", "No se pudo preparar el vídeo: \(why)")
      }
    }
  }

  // ---------- Recortar persona u objeto (stickers) ----------

  /// Quita el fondo de una foto y deja solo a la persona, mascota u objeto,
  /// como hace el iPhone al mantener pulsada una foto. Todo en el móvil.
  /// Devuelve la ruta de un PNG transparente recortado al sujeto.
  private func liftSubject(path: String, result: @escaping FlutterResult) {
    guard #available(iOS 17.0, *) else {
      fail(result, "unsupported", "Quitar el fondo necesita iOS 17 o más nuevo.")
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      guard let original = UIImage(contentsOfFile: path) else {
        self.fail(result, "bad_image", "No se pudo abrir la foto")
        return
      }
      // Dibuja la foto "derecha" para no lidiar con la orientación.
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let upright = UIGraphicsImageRenderer(size: original.size, format: format).image { _ in
        original.draw(in: CGRect(origin: .zero, size: original.size))
      }
      guard let cg = upright.cgImage else {
        self.fail(result, "bad_image", "No se pudo leer la foto")
        return
      }
      let handler = VNImageRequestHandler(cgImage: cg, options: [:])
      let request = VNGenerateForegroundInstanceMaskRequest()
      do {
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
          self.fail(result, "no_subject", "No encontré a nadie en la foto. Prueba con otra.")
          return
        }
        let buffer = try obs.generateMaskedImage(
          ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = CIContext().createCGImage(ci, from: ci.extent),
              let png = UIImage(cgImage: out).pngData() else {
          self.fail(result, "failed", "No se pudo recortar la foto")
          return
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("klk_cut_\(UUID().uuidString).png")
        try png.write(to: url)
        DispatchQueue.main.async { result(url.path) }
      } catch {
        self.fail(result, "failed", "No se pudo quitar el fondo: \(error.localizedDescription)")
      }
    }
  }

  // ---------- Avisos push (APNs) ----------

  /// Pide permiso para avisos y el token de Apple. Devuelve el token en hexadecimal,
  /// o nil si la persona no da permiso.
  private func registerPush(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      DispatchQueue.main.async {
        guard granted else {
          result(nil)
          return
        }
        if let old = self.pushResult {
          old(FlutterError(code: "replaced", message: "Otra petición en curso", details: nil))
        }
        self.pushResult = result
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushResult?(hex)
    pushResult = nil
  }

  public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    pushResult?(FlutterError(code: "failed", message: "No se pudieron activar los avisos: \(error.localizedDescription)", details: nil))
    pushResult = nil
  }

  // ---------- Capturas de pantalla ----------

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.sink?(true)
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let o = observer { NotificationCenter.default.removeObserver(o) }
    observer = nil
    sink = nil
    return nil
  }
}


// ---------- Subtítulos de llamada ----------

/// Pasa a texto lo que dice la persona por el micrófono, en directo y SIN salir
/// del iPhone (requiresOnDeviceRecognition). Envía {"t": texto, "f": esFinal}.
/// Las tareas de reconocimiento duran como mucho ~1 minuto: se encadenan solas.
final class LiveCaptions: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private let engine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var running = false
  private var tapped = false

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func start(locale: String, result: @escaping FlutterResult) {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else {
          result(FlutterError(code: "denied", message: "Activa el reconocimiento de voz para KLK en Ajustes del iPhone.", details: nil))
          return
        }
        var chosen: SFSpeechRecognizer?
        for id in [locale, "es-US", "es-MX", "es-ES", "en-US"] {
          if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable, r.supportsOnDeviceRecognition {
            chosen = r
            break
          }
        }
        guard let rec = chosen else {
          result(FlutterError(code: "no_on_device", message: "Este iPhone no puede pasar la voz a texto sin internet.", details: nil))
          return
        }
        self.recognizer = rec
        let input = self.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
          result(FlutterError(code: "no_mic", message: "El micrófono no está disponible ahora mismo.", details: nil))
          return
        }
        if !self.tapped {
          input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
          }
          self.tapped = true
        }
        do {
          self.engine.prepare()
          try self.engine.start()
        } catch {
          self.cleanup()
          result(FlutterError(code: "no_mic", message: "No se pudo usar el micrófono para los subtítulos: \(error.localizedDescription)", details: nil))
          return
        }
        self.running = true
        self.newTask()
        result(nil)
      }
    }
  }

  private func newTask() {
    guard running, let rec = recognizer else { return }
    task?.cancel()
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.requiresOnDeviceRecognition = true
    req.taskHint = .dictation
    request = req
    task = rec.recognitionTask(with: req) { [weak self] res, error in
      guard let self = self else { return }
      if let res = res {
        let text = res.bestTranscription.formattedString
        let final = res.isFinal
        DispatchQueue.main.async { self.sink?(["t": text, "f": final]) }
        if final { DispatchQueue.main.async { self.newTask() } }
      } else if error != nil {
        // Silencio largo o límite de tiempo: se empieza otra tarea.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.newTask() }
      }
    }
  }

  func stop() {
    running = false
    cleanup()
  }

  private func cleanup() {
    task?.cancel()
    task = nil
    request?.endAudio()
    request = nil
    if engine.isRunning { engine.stop() }
    if tapped {
      engine.inputNode.removeTap(onBus: 0)
      tapped = false
    }
  }
}
