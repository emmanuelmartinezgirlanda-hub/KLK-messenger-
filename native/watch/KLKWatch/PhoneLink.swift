import AVFoundation
import Foundation
import WatchConnectivity
import WatchKit

struct WatchContact: Identifiable, Hashable {
  let id: String
  let title: String
}

/// Conexión con el iPhone (WatchConnectivity).
/// - El iPhone manda la lista de contactos y los chats con sus últimos mensajes (applicationContext).
/// - El reloj manda notas de voz y respuestas de texto; el iPhone las cifra y las envía.
/// - El reloj manda sus grabaciones al iPhone (transferFile) y el iPhone las envía cifradas.
/// - El iPhone le pasa al reloj lo que te mandan por walkie, y suena solo.
final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate, AVAudioPlayerDelegate {
  static let shared = PhoneLink()

  @Published var contacts: [WatchContact] = []
  @Published var chats: [WatchChat] = []
  @Published var reachable = false
  @Published var playingFrom: String?  // quién está sonando ahora

  private var player: AVAudioPlayer?
  private var queue: [(URL, String)] = []

  override init() {
    super.init()
    if WCSession.isSupported() {
      WCSession.default.delegate = self
      WCSession.default.activate()
    }
    if let saved = UserDefaults.standard.array(forKey: "klk.chats") as? [[String: Any]] {
      chats = saved.compactMap(WatchChat.init)
    }
    if let saved = UserDefaults.standard.array(forKey: "klk.contacts") as? [[String: String]] {
      contacts = saved.compactMap { d in
        guard let id = d["id"], let t = d["title"] else { return nil }
        return WatchContact(id: id, title: t)
      }
    }
  }

  // MARK: enviar

  func send(file: URL, to contact: WatchContact, durationMs: Int) {
    guard WCSession.default.activationState == .activated else { return }
    WCSession.default.transferFile(file, metadata: ["type": "walkie", "chatId": contact.id, "ms": durationMs])
  }

  /// Nota de voz normal (no walkie) para un chat.
  func sendVoice(file: URL, chatId: String, durationMs: Int) {
    guard WCSession.default.activationState == .activated else { return }
    WCSession.default.transferFile(file, metadata: ["type": "voice", "chatId": chatId, "ms": durationMs])
    appendMine(chatId: chatId, text: "🎤 Nota de voz")
  }

  /// Respuesta de texto (dictada, escrita o rápida).
  func sendText(_ text: String, chatId: String) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, WCSession.default.activationState == .activated else { return }
    WCSession.default.transferUserInfo(["type": "text", "chatId": chatId, "text": t])
    appendMine(chatId: chatId, text: t)
  }

  /// Lo enseño ya en el reloj; el iPhone mandará la lista buena enseguida.
  private func appendMine(chatId: String, text: String) {
    guard let i = chats.firstIndex(where: { $0.id == chatId }) else { return }
    chats[i].messages.append(
      WatchMessage(id: UUID().uuidString, mine: true, from: "", text: text, at: Date()))
  }

  /// Al abrir un chat en el reloj: quito el número de no leídos (en el reloj).
  func markSeen(_ chatId: String) {
    guard let i = chats.firstIndex(where: { $0.id == chatId }) else { return }
    chats[i].unread = 0
  }

  // MARK: WCSessionDelegate

  func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    DispatchQueue.main.async {
      self.reachable = session.isReachable
      self.apply(session.receivedApplicationContext)
    }
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    DispatchQueue.main.async { self.reachable = session.isReachable }
  }

  func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    DispatchQueue.main.async { self.apply(applicationContext) }
  }

  private func apply(_ ctx: [String: Any]) {
    if let list = ctx["chats"] as? [[String: Any]] {
      UserDefaults.standard.set(list, forKey: "klk.chats")
      chats = list.compactMap(WatchChat.init)
    }
    guard let list = ctx["contacts"] as? [[String: String]] else { return }
    UserDefaults.standard.set(list, forKey: "klk.contacts")
    contacts = list.compactMap { d in
      guard let id = d["id"], let t = d["title"] else { return nil }
      return WatchContact(id: id, title: t)
    }
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    // El archivo se borra al volver de este método: lo copio.
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    try? FileManager.default.copyItem(at: file.fileURL, to: dest)
    let from = file.metadata?["from"] as? String ?? ""
    DispatchQueue.main.async {
      self.queue.append((dest, from))
      self.playNext()
    }
  }

  // MARK: sonar

  private func playNext() {
    guard player == nil || !(player?.isPlaying ?? false), !queue.isEmpty else { return }
    let (url, from) = queue.removeFirst()
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
      try AVAudioSession.sharedInstance().setActive(true)
      let p = try AVAudioPlayer(contentsOf: url)
      p.delegate = self
      player = p
      playingFrom = from
      WKInterfaceDevice.current().play(.notification)
      p.play()
    } catch {
      playNext()
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    DispatchQueue.main.async {
      self.playingFrom = nil
      self.player = nil
      self.playNext()
    }
  }

  func stopPlaying() {
    player?.stop()
    player = nil
    playingFrom = nil
  }
}
