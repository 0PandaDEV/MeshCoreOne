import Foundation
import MC1Services

/// What the Connection row and the Connection page show for the phone's link.
enum ConnectionLinkRows {
  struct Snapshot: Equatable, Sendable {
    var rows: [Row]
    var checked: TransportType?
    var target: TransportType?
    var settingsDetail: SettingsDetail
  }

  struct Row: Equatable, Sendable, Identifiable {
    var link: TransportType
    /// Host with no port. Nil when the Wi-Fi row has nothing to show under the title.
    var address: String?

    var id: TransportType {
      link
    }
  }

  enum SettingsDetail: Equatable, Sendable {
    case bluetooth
    case host(String)
    case wifi
  }

  /// While `activeSwitch` exists, it supplies the rows, the check, the target, and the host.
  /// Otherwise Bluetooth follows the live transport or a saved peripheral id, and Wi-Fi follows the live transport or `showsConnectOverWiFi`.
  static func make(
    liveTransport: TransportType?,
    savedPeripheralID: UUID?,
    liveWiFiHost: String?,
    showsConnectOverWiFi: Bool,
    activeSwitch: ConnectionLinkSwitch?
  ) -> Snapshot {
    if let activeSwitch {
      return snapshot(from: activeSwitch)
    }

    let checked = liveTransport
    var rows: [Row] = []
    if liveTransport == .bluetooth || savedPeripheralID != nil {
      rows.append(Row(link: .bluetooth, address: nil))
    }
    let host = displayHost(liveWiFiHost)
    if liveTransport == .wifi || showsConnectOverWiFi {
      rows.append(Row(link: .wifi, address: host))
    }
    let checkedHost = checked == .wifi ? host : nil
    return Snapshot(
      rows: rows,
      checked: checked,
      target: nil,
      settingsDetail: settingsDetail(checked: checked, displayHost: checkedHost)
    )
  }

  private static func snapshot(from record: ConnectionLinkSwitch) -> Snapshot {
    var rows: [Row] = []
    if record.checked == .bluetooth || record.bluetoothPeripheralID != nil || record.target == .bluetooth {
      rows.append(Row(link: .bluetooth, address: nil))
    }
    let host = record.wifi?.displayHost
    if record.checked == .wifi || record.wifi != nil || record.target == .wifi {
      rows.append(Row(link: .wifi, address: host))
    }
    return Snapshot(
      rows: rows,
      checked: record.checked,
      target: record.target,
      settingsDetail: settingsDetail(checked: record.checked, displayHost: record.displayHost)
    )
  }

  private static func settingsDetail(checked: TransportType?, displayHost: String?) -> SettingsDetail {
    switch checked {
    case .bluetooth, nil:
      .bluetooth
    case .wifi:
      if let displayHost {
        .host(displayHost)
      } else {
        .wifi
      }
    }
  }

  private static func displayHost(_ host: String?) -> String? {
    guard let host else { return nil }
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed
  }
}
