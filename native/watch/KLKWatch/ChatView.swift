import AVFoundation
import SwiftUI
import WatchKit

/// Un chat en el reloj: lees los últimos mensajes y respondes con una nota de
/// voz, dictando o con una respuesta rápida. El iPhone lo cifra y lo envía.
struct ChatView: View {
  let chatId: String
  @EnvironmentObject var link: PhoneLink
  @State private var showVoice = false
  @State private var draft = ""

  private static let quick = ["Klk 👋", "Ya voy", "Ahorita te llamo", "Dale 👍", "Ok", "Te quiero ❤️"]

  private var chat: WatchChat? { link.chats.first { $0.id == chatId } }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          if let c = chat {
            if c.messages.isEmpty {
              Text("Aún no hay mensajes.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(c.messages) { m in
              bubble(m, group: c.group).id(m.id)
            }
          }
          Button {
            showVoice = true
          } label: {
            Label("Nota de voz", systemImage: "mic.fill")
          }
          .tint(.red)
          .padding(.top, 6)
          .id("bottom")

          TextField("Escribir o dictar", text: $draft)
            .onSubmit {
              link.sendText(draft, chatId: chatId)
              draft = ""
              WKInterfaceDevice.current().play(.success)
            }

          ForEach(Self.quick, id: \.self) { q in
            Button(q) {
              link.sendText(q, chatId: chatId)
              WKInterfaceDevice.current().play(.success)
              withAnimation { proxy.scrollTo("bottom") }
            }
            .font(.footnote)
          }
        }
        .padding(.horizontal, 2)
      }
      .onAppear {
        link.markSeen(chatId)
        if let last = chat?.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
      }
    }
    .navigationTitle(chat?.title ?? "Chat")
    .sheet(isPresented: $showVoice) {
      VoiceNoteView(chatId: chatId)
    }
  }

  @ViewBuilder
  private func bubble(_ m: WatchMessage, group: Bool) -> some View {
    HStack {
      if m.mine { Spacer(minLength: 16) }
      VStack(alignment: .leading, spacing: 1) {
        if group && !m.mine && !m.from.isEmpty {
          Text(m.from).font(.caption2.bold()).foregroundStyle(.orange)
        }
        Text(m.text).font(.footnote)
        Text(m.at.klkShort).font(.system(size: 9)).foregroundStyle(.secondary)
      }
      .padding(6)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(m.mine ? Color(red: 0, green: 0.18, blue: 0.38) : Color.gray.opacity(0.3)))
      if !m.mine { Spacer(minLength: 16) }
    }
  }
}

/// Grabar una nota de voz: toca para empezar, toca para enviar.
struct VoiceNoteView: View {
  let chatId: String
  @EnvironmentObject var link: PhoneLink
  @Environment(\.dismiss) private var dismiss
  @State private var recorder: AVAudioRecorder?
  @State private var start = Date()
  @State private var now = Date()
  @State private var status = "Toca para grabar"
  private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 8) {
      Text(recorder == nil ? status : elapsed).font(.headline).monospacedDigit()
      Button {
        recorder == nil ? begin() : finish()
      } label: {
        Image(systemName: recorder == nil ? "mic.fill" : "paperplane.fill")
          .font(.system(size: 34))
          .frame(width: 80, height: 80)
          .background(Circle().fill(recorder == nil ? Color.red : Color.green))
      }
      .buttonStyle(.plain)
      if recorder != nil {
        Button("Cancelar", role: .destructive) { cancel() }.font(.footnote)
      }
    }
    .onReceive(tick) { now = $0 }
    .onDisappear { if recorder != nil { cancel() } }
  }

  private var elapsed: String {
    let s = Int(now.timeIntervalSince(start))
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  private func begin() {
    AVAudioApplication.requestRecordPermission { ok in
      DispatchQueue.main.async {
        guard ok else { status = "Permite el micrófono"; return }
        do {
          try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
          try AVAudioSession.sharedInstance().setActive(true)
          let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
          let r = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
          ])
          r.record()
          recorder = r
          start = Date()
          now = start
          WKInterfaceDevice.current().play(.start)
        } catch {
          status = "No se pudo grabar"
        }
      }
    }
  }

  private func finish() {
    guard let r = recorder else { return }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    r.stop()
    recorder = nil
    if ms < 700 {
      try? FileManager.default.removeItem(at: r.url)
      status = "Muy corta. Toca para grabar"
      return
    }
    link.sendVoice(file: r.url, chatId: chatId, durationMs: ms)
    WKInterfaceDevice.current().play(.success)
    dismiss()
  }

  private func cancel() {
    recorder?.stop()
    if let u = recorder?.url { try? FileManager.default.removeItem(at: u) }
    recorder = nil
  }
}
