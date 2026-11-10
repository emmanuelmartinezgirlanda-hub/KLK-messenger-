import Foundation

/// Un mensaje que el iPhone le pasa al reloj (ya descifrado, solo para leer).
struct WatchMessage: Identifiable, Hashable {
  let id: String
  let mine: Bool
  let from: String
  let text: String
  let at: Date
}

/// Un chat con sus últimos mensajes.
struct WatchChat: Identifiable, Hashable {
  let id: String
  let title: String
  let group: Bool
  var unread: Int
  let last: String
  let at: Date
  var messages: [WatchMessage]

  init?(_ d: [String: Any]) {
    guard let id = d["id"] as? String, let title = d["title"] as? String else { return nil }
    self.id = id
    self.title = title
    group = d["group"] as? Bool ?? false
    unread = (d["unread"] as? NSNumber)?.intValue ?? 0
    last = d["last"] as? String ?? ""
    at = Date(timeIntervalSince1970: ((d["at"] as? NSNumber)?.doubleValue ?? 0) / 1000)
    messages = (d["messages"] as? [[String: Any]] ?? []).compactMap { m in
      guard let mid = m["id"] as? String else { return nil }
      return WatchMessage(
        id: mid,
        mine: m["mine"] as? Bool ?? false,
        from: m["from"] as? String ?? "",
        text: m["text"] as? String ?? "",
        at: Date(timeIntervalSince1970: ((m["at"] as? NSNumber)?.doubleValue ?? 0) / 1000))
    }
  }
}

extension Date {
  /// «14:05», «ayer» o «3/11».
  var klkShort: String {
    let cal = Calendar.current
    if cal.isDateInToday(self) {
      let f = DateFormatter()
      f.dateFormat = "HH:mm"
      return f.string(from: self)
    }
    if cal.isDateInYesterday(self) { return "ayer" }
    let f = DateFormatter()
    f.dateFormat = "d/M"
    return f.string(from: self)
  }
}
