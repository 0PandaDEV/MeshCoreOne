import Foundation
import MC1Services

/// Host and port captured for a Wi-Fi dial. The row shows the host alone.
struct ConnectionLinkWiFiDial: Equatable, Sendable {
  var host: String
  var port: UInt16

  var displayHost: String? {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed
  }

  var canDial: Bool {
    displayHost != nil
  }

  static func capture(
    liveTransport: TransportType?,
    savedWiFi: ConnectionMethod?,
    snapshotHost: String?
  ) -> ConnectionLinkWiFiDial? {
    if liveTransport == .wifi, case let .wifi(host, port, _) = savedWiFi {
      return ConnectionLinkWiFiDial(host: host, port: port)
    }
    guard let snapshotHost else { return nil }
    let host = snapshotHost.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty else { return nil }
    return ConnectionLinkWiFiDial(host: host, port: ConnectionMethod.defaultWiFiPort)
  }
}
