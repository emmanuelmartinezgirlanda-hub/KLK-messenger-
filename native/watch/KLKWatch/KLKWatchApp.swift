import SwiftUI

/// KLK para Apple Watch: walkie-talkie con tus contactos.
/// El reloj no habla con el servidor: graba, y el iPhone lo cifra y lo envía.
@main
struct KLKWatchApp: App {
  @StateObject private var link = PhoneLink.shared

  var body: some Scene {
    WindowGroup {
      NavigationStack {
        ContactsView()
      }
      .environmentObject(link)
    }
  }
}
