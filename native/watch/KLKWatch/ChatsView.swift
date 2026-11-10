import SwiftUI

/// Pantalla principal del reloj: tus chats, como en el iPhone.
struct ChatsView: View {
  @EnvironmentObject var link: PhoneLink

  var body: some View {
    List {
      if link.chats.isEmpty {
        Text("Abre KLK en tu iPhone para ver tus chats aquí.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach(link.chats) { c in
        NavigationLink(value: c.id) {
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              if c.group { Image(systemName: "person.3.fill").font(.caption2) }
              Text(c.title).font(.headline).lineLimit(1)
              Spacer(minLength: 2)
              if c.unread > 0 {
                Text("\(c.unread)")
                  .font(.caption2.bold())
                  .padding(.horizontal, 6)
                  .background(Capsule().fill(Color.red))
              }
            }
            Text(c.last).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            Text(c.at.klkShort).font(.caption2).foregroundStyle(.tertiary)
          }
          .padding(.vertical, 2)
        }
      }
      if !link.contacts.isEmpty {
        NavigationLink {
          ContactsView()
        } label: {
          Label("Walkie", systemImage: "antenna.radiowaves.left.and.right")
        }
      }
    }
    .navigationTitle("KLK")
    .navigationDestination(for: String.self) { id in
      ChatView(chatId: id)
    }
  }
}
