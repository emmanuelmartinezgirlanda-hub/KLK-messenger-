import SwiftUI

/// KLK para Apple Watch: tus chats (leer y responder con voz o texto) y walkie-talkie.
/// El reloj no habla con el servidor: graba, y el iPhone lo cifra y lo envía.
@main
struct KLKWatchApp: App {
  @StateObject private var link = PhoneLink.shared

  var body: some Scene {
    WindowGroup {
      NavigationStack {
        ChatsView()
      }
      .environmentObject(link)
    }
  }
}
