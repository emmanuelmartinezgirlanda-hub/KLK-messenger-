import AVFoundation
import SwiftUI
import WatchKit

/// Mantén pulsado el botón, habla y suelta: se manda al iPhone, que lo envía cifrado.
struct WalkieView: View {
  let contact: WatchContact
  @EnvironmentObject var link: PhoneLink
  @State private var recorder: AVAudioRecorder?
  @State private var talking = false
  @State private var start = Date()
  @State private var status = "Mantén y habla"

  var body: some View {
    VStack(spacing: 6) {
      Text(contact.title).font(.headline).lineLimit(1)
      Circle()
        .fill(talking ? Color.red : (link.playingFrom != nil ? Color.green : Color.blue))
        .overlay(
          Image(systemName: talking ? "mic.fill" : (link.playingFrom != nil ? "speaker.wave.2.fill" : "mic"))
            .font(.system(size: 40))
            .foregroundStyle(.white)
        )
        .scaleEffect(talking ? 1.08 : 1)
        .animation(.easeInOut(duration: 0.2), value: talking)
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { _ in if !talking { begin() } }
            .onEnded { _ in end() }
        )
      Text(link.playingFrom != nil ? "Te están hablando…" : status)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal)
  }

  private func begin() {
    link.stopPlaying()
    AVAudioApplication.requestRecordPermission { ok in
      DispatchQueue.main.async {
        guard ok else { status = "Permite el micrófono en el reloj"; return }
        startRecording()
      }
    }
    talking = true
    WKInterfaceDevice.current().play(.start)
  }

  private func startRecording() {
    guard talking else { return }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
      try AVAudioSession.sharedInstance().setActive(true)
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 22050,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
      ]
      let r = try AVAudioRecorder(url: url, settings: settings)
      r.record()
      recorder = r
      start = Date()
      status = "Hablando… suelta para enviar"
    } catch {
      talking = false
      status = "No se pudo grabar"
    }
  }

  private func end() {
    guard talking else { return }
    talking = false
    WKInterfaceDevice.current().play(.stop)
    guard let r = recorder else { return }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    r.stop()
    recorder = nil
    if ms < 600 {
      try? FileManager.default.removeItem(at: r.url)
      status = "Mantén pulsado mientras hablas"
      return
    }
    link.send(file: r.url, to: contact, durationMs: ms)
    status = "Enviado ✓"
  }
}
