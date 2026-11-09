import AVFoundation
import CallKit
import Flutter
import PushKit
import UIKit

/// Llamadas con el iPhone bloqueado: el servidor manda un aviso de llamada
/// (PushKit/VoIP) y aquí se enseña la pantalla de llamada de Apple (CallKit).
/// Cuando contestas o cuelgas, se lo decimos a Flutter, que conecta la llamada
/// cifrada como siempre.
final class CallKitBridge: NSObject, FlutterStreamHandler, PKPushRegistryDelegate, CXProviderDelegate {
  static let shared = CallKitBridge()

  private var registry: PKPushRegistry?
  private let provider: CXProvider
  private let controller = CXCallController()
  private var sink: FlutterEventSink?
  private var queued: [[String: Any]] = []
  private(set) var voipToken: String?

  /// id de llamada de KLK <-> UUID de CallKit
  private var uuids: [String: UUID] = [:]
  private var ids: [UUID: String] = [:]

  private override init() {
    let cfg: CXProviderConfiguration
    if #available(iOS 14.0, *) {
      cfg = CXProviderConfiguration()
    } else {
      cfg = CXProviderConfiguration(localizedName: "KLK")
    }
    cfg.supportsVideo = true
    cfg.maximumCallsPerCallGroup = 1
    cfg.maximumCallGroups = 1
    cfg.supportedHandleTypes = [.generic]
    cfg.includesCallsInRecents = true
    if let icon = UIImage(named: "AppIcon") ?? UIImage(named: "LaunchImage") {
      cfg.iconTemplateImageData = icon.pngData()
    }
    provider = CXProvider(configuration: cfg)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  /// Se llama al arrancar la app (registro del plugin): hay que estar listo
  /// para recibir el aviso de llamada cuanto antes.
  func start() {
    guard registry == nil else { return }
    let r = PKPushRegistry(queue: .main)
    r.delegate = self
    r.desiredPushTypes = [.voIP]
    registry = r
  }

  // MARK: Flutter

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let pending = queued
    queued.removeAll()
    for e in pending { events(e) }
    if let t = voipToken { events(["type": "token", "token": t]) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ e: [String: Any]) {
    DispatchQueue.main.async {
      if let s = self.sink { s(e) } else { self.queued.append(e) }
    }
  }

  /// La llamada terminó en KLK (colgó alguien, no se pudo conectar…): quita la pantalla de Apple.
  func end(callId: String) {
    guard let u = uuids[callId] else { return }
    provider.reportCall(with: u, endedAt: Date(), reason: .remoteEnded)
    forget(u)
  }

  /// La llamada ya está conectada (para el contador de la pantalla de Apple).
  func connected(callId: String) {
    guard let u = uuids[callId] else { return }
    provider.reportOutgoingCall(with: u, connectedAt: Date())
  }

  private func forget(_ u: UUID) {
    if let id = ids[u] { uuids[id] = nil }
    ids[u] = nil
  }

  // MARK: PushKit

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    voipToken = token
    emit(["type": "token", "token": token])
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    voipToken = nil
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                    for type: PKPushType, completion: @escaping () -> Void) {
    let info = payload.dictionaryPayload["klk"] as? [String: Any] ?? [:]
    let callId = info["id"] as? String ?? UUID().uuidString
    let from = info["from"] as? String ?? ""
    let video = info["v"] as? Bool ?? false
    let group = info["g"] as? String ?? ""
    var name = (info["n"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    if name.isEmpty { name = "KLK" }

    // iOS exige enseñar SIEMPRE la pantalla de llamada al recibir un aviso VoIP.
    let u = uuids[callId] ?? UUID()
    uuids[callId] = u
    ids[u] = callId
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: name)
    update.localizedCallerName = name
    update.hasVideo = video
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    provider.reportNewIncomingCall(with: u, update: update) { error in
      if error != nil { self.forget(u) }
      completion()
    }
    emit(["type": "incoming", "id": callId, "from": from, "video": video, "group": group, "name": name])
  }

  // MARK: CallKit

  func providerDidReset(_ provider: CXProvider) {
    for (u, id) in ids {
      emit(["type": "end", "id": id])
      forget(u)
    }
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    if let id = ids[action.callUUID] { emit(["type": "answer", "id": id]) }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if let id = ids[action.callUUID] { emit(["type": "end", "id": id]) }
    forget(action.callUUID)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if let id = ids[action.callUUID] { emit(["type": "mute", "id": id, "muted": action.isMuted]) }
    action.fulfill()
  }

  // El audio de la llamada lo activa CallKit: se lo pasamos a WebRTC.
  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    rtcAudio("audioSessionDidActivate:", audioSession)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    rtcAudio("audioSessionDidDeactivate:", audioSession)
  }

  private func rtcAudio(_ selector: String, _ session: AVAudioSession) {
    guard let cls = NSClassFromString("RTCAudioSession") as? NSObject.Type else { return }
    let shared = NSSelectorFromString("sharedInstance")
    guard cls.responds(to: shared), let inst = cls.perform(shared)?.takeUnretainedValue() as? NSObject else { return }
    let sel = NSSelectorFromString(selector)
    if inst.responds(to: sel) { _ = inst.perform(sel, with: session) }
    let enabled = NSSelectorFromString("setIsAudioEnabled:")
    if inst.responds(to: enabled) {
      inst.setValue(selector == "audioSessionDidActivate:", forKey: "isAudioEnabled")
    }
  }
}
