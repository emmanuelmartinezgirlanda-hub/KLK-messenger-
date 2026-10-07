import Flutter
import Speech
import UIKit

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

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = KlkNativePlugin()
    let channel = FlutterMethodChannel(name: "klk/native", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(name: "klk/screenshots", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "transcribe":
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "Falta el archivo", details: nil))
        return
      }
      transcribe(path: path, locale: (args["locale"] as? String) ?? "es-ES", result: result)
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
