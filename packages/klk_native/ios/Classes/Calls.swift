import AVFoundation
import CallKit
import Flutter
import PushKit
import UIKit

/// Llamadas con el iPhone bloqueado (como WhatsApp):
/// - PushKit: el servidor manda un aviso VoIP que despierta KLK aunque esté cerrada.
/// - CallKit: la pantalla de llamada del iPhone, que suena y se ve bloqueado.
/// El audio y el vídeo siguen yendo cifrados entre los dos móviles (WebRTC);
/// aquí solo se enseña la llamada y se le dice a Dart si se contesta o se cuelga.
///
/// Canal "klk/calls":
///   Dart → iPhone: ready, voipToken, has {id}, answered {id}, end {id, reason}
///   iPhone → Dart: token {token}, incoming {id, video, from}, answer {id}, end {id}
final class Calls: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
  static let shared = Calls()

  private var channel: FlutterMethodChannel?
  private var registry: PKPushRegistry?
  private let provider: CXProvider
  private let controller = CXCallController()

  private var token: String?
  private var dartReady = false
  private var pending: [(String, [String: Any])] = []

  /// Llamadas que enseña CallKit: id de KLK ↔ UUID de CallKit.
  private var uuids: [String: UUID] = [:]
  private var ids: [UUID: String] = [:]
  private var answered: Set<UUID> = []
  private var timeouts: [UUID: DispatchWorkItem] = [:]

  private override init() {
    let config: CXProviderConfiguration
    if #available(iOS 14.0, *) {
      config = CXProviderConfiguration()
    } else {
      config = CXProviderConfiguration(localizedName: "KLK messenger")
    }
    config.supportsVideo = true
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.phoneNumber, .generic]
    config.includesCallsInRecents = false
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  /// Se llama al arrancar la app (también cuando la despierta un aviso VoIP).
  func start(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "klk/calls", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    channel = ch
    if registry == nil {
      let r = PKPushRegistry(queue: .main)
      r.delegate = self
      r.desiredPushTypes = [.voIP]
      registry = r
    }
  }

  // ---------- Dart → iPhone ----------

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["id"] as? String ?? ""
    switch call.method {
    case "ready":
      dartReady = true
      let queued = pending
      pending = []
      for (m, a) in queued { channel?.invokeMethod(m, arguments: a) }
      result(nil)
    case "voipToken":
      result(token)
    case "has":
      result(uuids[id] != nil)
    case "answered":
      // Contestó desde la pantalla de KLK: se lo decimos a CallKit (activa el audio).
      if let u = uuids[id], !answered.contains(u) {
        answered.insert(u)
        cancelTimeout(u)
        controller.request(CXTransaction(action: CXAnswerCallAction(call: u))) { _ in }
      }
      result(nil)
    case "end":
      if let u = uuids[id] {
        let reason: CXCallEndedReason
        switch (args["reason"] as? String) ?? "" {
        case "unanswered": reason = .unanswered
        case "declined": reason = .declinedElsewhere
        case "failed": reason = .failed
        default: reason = .remoteEnded
        }
        provider.reportCall(with: u, endedAt: Date(), reason: reason)
        forget(u)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func send(_ method: String, _ args: [String: Any]) {
    if dartReady, let ch = channel {
      ch.invokeMethod(method, arguments: args)
    } else {
      pending.append((method, args))
    }
  }

  // ---------- PushKit ----------

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    token = hex
    send("token", ["token": hex])
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    token = nil
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                    for type: PKPushType, completion: @escaping () -> Void) {
    let info = payload.dictionaryPayload["call"] as? [String: Any] ?? [:]
    let id = info["id"] as? String ?? ""
    let video = info["video"] as? Bool ?? false
    let from = info["from"] as? String ?? ""
    let handle = info["handle"] as? String ?? ""
    let name = info["name"] as? String ?? ""

    // Apple exige enseñar SIEMPRE una llamada por cada aviso VoIP.
    if !id.isEmpty, let existing = uuids[id] {
      // Aviso repetido de la misma llamada: ya está sonando.
      let update = CXCallUpdate()
      update.hasVideo = video
      provider.reportCall(with: existing, updated: update)
      completion()
      return
    }
    let u = UUID(uuidString: id) ?? UUID()
    let update = CXCallUpdate()
    if !handle.isEmpty {
      // Con el número, el iPhone pone el nombre de la agenda.
      update.remoteHandle = CXHandle(type: .phoneNumber, value: handle)
    } else {
      update.remoteHandle = CXHandle(type: .generic, value: name.isEmpty ? "KLK messenger" : name)
      update.localizedCallerName = name.isEmpty ? "KLK messenger" : name
    }
    update.hasVideo = video
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false

    provider.reportNewIncomingCall(with: u, update: update) { [weak self] error in
      guard let self = self else { completion(); return }
      if error == nil && !id.isEmpty {
        self.uuids[id] = u
        self.ids[u] = id
        self.send("incoming", ["id": id, "video": video, "from": from])
        // Por si la app no llega a conectarse: que no suene para siempre.
        let work = DispatchWorkItem { [weak self] in
          guard let self = self, self.ids[u] != nil, !self.answered.contains(u) else { return }
          self.provider.reportCall(with: u, endedAt: Date(), reason: .unanswered)
          self.send("end", ["id": id])
          self.forget(u)
        }
        self.timeouts[u] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 50, execute: work)
      } else if error == nil {
        // Aviso sin datos de llamada: se enseña y se cierra (Apple lo exige).
        self.provider.reportCall(with: u, endedAt: Date(), reason: .failed)
      }
      completion()
    }
  }

  // ---------- CallKit ----------

  func providerDidReset(_ provider: CXProvider) {
    for (u, id) in ids { send("end", ["id": id]); cancelTimeout(u) }
    uuids = [:]
    ids = [:]
    answered = []
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    let u = action.callUUID
    answered.insert(u)
    cancelTimeout(u)
    if let id = ids[u] { send("answer", ["id": id]) }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    let u = action.callUUID
    if let id = ids[u] { send("end", ["id": id]) }
    forget(u)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    webRTCAudio(audioSession, active: true)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    webRTCAudio(audioSession, active: false)
  }

  /// Avisa al audio de WebRTC (flutter_webrtc) de que CallKit activó o soltó
  /// el audio. Se hace sin enlazar WebRTC aquí: si la clase no está, no pasa nada.
  private func webRTCAudio(_ session: AVAudioSession, active: Bool) {
    guard let cls: AnyClass = NSClassFromString("RTCAudioSession") else { return }
    let sharedSel = NSSelectorFromString("sharedInstance")
    guard let m = class_getClassMethod(cls, sharedSel) else { return }
    typealias SharedFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    let fn = unsafeBitCast(method_getImplementation(m), to: SharedFn.self)
    guard let shared = fn(cls, sharedSel)?.takeUnretainedValue() as? NSObject else { return }
    let sel = NSSelectorFromString(active ? "audioSessionDidActivate:" : "audioSessionDidDeactivate:")
    if shared.responds(to: sel) { shared.perform(sel, with: session) }
  }

  private func cancelTimeout(_ u: UUID) {
    timeouts[u]?.cancel()
    timeouts[u] = nil
  }

  private func forget(_ u: UUID) {
    cancelTimeout(u)
    if let id = ids[u] { uuids[id] = nil }
    ids[u] = nil
    answered.remove(u)
  }
}
