import SwiftUI

struct ContactsView: View {
  @EnvironmentObject var link: PhoneLink

  var body: some View {
    List {
      if link.contacts.isEmpty {
        Text("Abre KLK en tu iPhone para ver tus contactos aquí.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach(link.contacts) { c in
        NavigationLink(value: c) {
          HStack {
            Image(systemName: "mic.circle.fill").foregroundStyle(.red)
            Text(c.title).lineLimit(1)
          }
        }
      }
    }
    .navigationTitle("📻 Walkie")
    .navigationDestination(for: WatchContact.self) { c in
      WalkieView(contact: c)
    }
  }
}
