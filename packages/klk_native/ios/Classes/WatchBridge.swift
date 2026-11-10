import Flutter
import Foundation
import WatchConnectivity

/// Puente con KLK del Apple Watch (walkie-talkie).
/// - Dart → reloj: lista de contactos ("watchContacts") y audios recibidos ("watchPlay").
/// - Reloj → Dart: grabaciones del reloj, por el canal de eventos "klk/watch".
final class WatchBridge: NSObject, WCSessionDelegate, FlutterStreamHandler {
  static let shared = WatchBridge()
  private var sink: FlutterEventSink?
  private var pending: [[String: Any]] = []  // llegaron antes de que Dart escuchara
  // applicationContext se sustituye entero: guardo las dos partes.
  private static var ctxContacts: [[String: String]] = []
  private static var ctxChats: [[String: Any]] = []

  private static func pushContext() -> Bool {
    guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
    do {
      try WCSession.default.updateApplicationContext(["contacts": ctxContacts, "chats": ctxChats])
      return true
    } catch {
      return false
    }
  }

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  /// true si respondió a la llamada.
  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "watchContacts":
      ctxContacts = args["contacts"] as? [[String: String]] ?? []
      result(pushContext())
      return true
    case "watchChats":
      ctxChats = args["chats"] as? [[String: Any]] ?? []
      result(pushContext())
      return true
    case "watchPlay":
      guard WCSession.isSupported(), WCSession.default.activationState == .activated,
        WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
        let path = args["path"] as? String
      else { result(false); return true }
      WCSession.default.transferFile(
        URL(fileURLWithPath: path),
        metadata: ["type": "walkie", "chatId": args["chatId"] as? String ?? "", "from": args["from"] as? String ?? ""])
      result(true)
      return true
    case "watchAvailable":
      result(WCSession.isSupported() && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled)
      return true
    default:
      return false
    }
  }

  // MARK: FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    for e in pending { events(e) }
    pending.removeAll()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ e: [String: Any]) {
    DispatchQueue.main.async {
      if let s = self.sink { s(e) } else { self.pending.append(e) }
    }
  }

  // MARK: WCSessionDelegate

  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
  func sessionDidBecomeInactive(_ session: WCSession) {}
  func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

  /// Respuestas de texto del reloj.
  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard let chatId = userInfo["chatId"] as? String, let text = userInfo["text"] as? String else { return }
    emit(["type": "text", "chatId": chatId, "text": text])
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    // El sistema borra el archivo al salir de aquí: lo copio a Documentos.
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dest = dir.appendingPathComponent("watch-" + UUID().uuidString + ".m4a")
    do {
      try FileManager.default.copyItem(at: file.fileURL, to: dest)
    } catch {
      return
    }
    let md = file.metadata ?? [:]
    emit([
      "type": md["type"] as? String ?? "walkie",
      "chatId": md["chatId"] as? String ?? "",
      "ms": md["ms"] as? Int ?? 0,
      "path": dest.path,
    ])
  }
}
