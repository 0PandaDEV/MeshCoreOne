import Foundation
@testable import MC1
@testable import MC1Services
import Testing

@Suite("Connection link rows")
struct ConnectionLinkRowsTests {
  private static let peripheral = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
  private static let radio = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
  private static let device = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

  @Test(arguments: cases)
  func `rows follow the live link the snapshot and the record`(_ row: RowCase) {
    let snapshot = ConnectionLinkRows.make(
      liveTransport: row.live,
      savedPeripheralID: row.peripheral,
      liveWiFiHost: row.host,
      showsConnectOverWiFi: row.showsWiFi,
      activeSwitch: row.record
    )
    #expect(snapshot.rows.map(\.link) == row.links)
    #expect(snapshot.rows.map(\.address) == row.addresses)
    #expect(snapshot.checked == row.checked)
    #expect(snapshot.target == row.target)
    #expect(snapshot.settingsDetail == row.detail)
  }

  @Test
  func `a record hides nothing the tap showed`() {
    let record = Self.heldRecord(checked: .bluetooth, target: .wifi, host: "10.0.0.8")
    let snapshot = ConnectionLinkRows.make(
      liveTransport: nil,
      savedPeripheralID: nil,
      liveWiFiHost: nil,
      showsConnectOverWiFi: false,
      activeSwitch: record
    )
    #expect(snapshot.rows.map(\.link) == [.bluetooth, .wifi])
    #expect(snapshot.rows.map(\.address) == [nil, "10.0.0.8"])
    #expect(snapshot.checked == .bluetooth)
    #expect(snapshot.target == .wifi)
  }

  private static let cases: [RowCase] = [
    RowCase(
      name: "Bluetooth before the snapshot",
      live: .bluetooth,
      peripheral: peripheral,
      host: "192.168.1.9",
      showsWiFi: false,
      links: [.bluetooth],
      addresses: [nil],
      checked: .bluetooth,
      detail: .bluetooth
    ),
    RowCase(
      name: "Bluetooth after a connected address",
      live: .bluetooth,
      peripheral: peripheral,
      host: "10.0.0.8",
      showsWiFi: true,
      links: [.bluetooth, .wifi],
      addresses: [nil, "10.0.0.8"],
      checked: .bluetooth,
      detail: .bluetooth
    ),
    RowCase(
      name: "Bluetooth after a finished snapshot with no address",
      live: .bluetooth,
      peripheral: peripheral,
      host: "192.168.1.9",
      showsWiFi: false,
      links: [.bluetooth],
      addresses: [nil],
      checked: .bluetooth,
      detail: .bluetooth
    ),
    RowCase(
      name: "Wi-Fi with a host",
      live: .wifi,
      peripheral: peripheral,
      host: "10.0.0.4",
      showsWiFi: false,
      links: [.bluetooth, .wifi],
      addresses: [nil, "10.0.0.4"],
      checked: .wifi,
      detail: .host("10.0.0.4")
    ),
    RowCase(
      name: "Wi-Fi with an empty host",
      live: .wifi,
      peripheral: peripheral,
      host: "",
      showsWiFi: false,
      links: [.bluetooth, .wifi],
      addresses: [nil, nil],
      checked: .wifi,
      detail: .wifi
    ),
    RowCase(
      name: "no peripheral id",
      live: .wifi,
      peripheral: nil,
      host: "10.0.0.4",
      showsWiFi: false,
      links: [.wifi],
      addresses: ["10.0.0.4"],
      checked: .wifi,
      detail: .host("10.0.0.4")
    ),
    RowCase(
      name: "nil transport and nil peripheral",
      live: nil,
      peripheral: nil,
      host: nil,
      showsWiFi: false,
      links: [],
      addresses: [],
      checked: nil,
      detail: .bluetooth
    ),
    RowCase(
      name: "held record while the live transport is nil",
      live: nil,
      peripheral: nil,
      host: nil,
      showsWiFi: false,
      record: heldRecord(checked: .bluetooth, target: .wifi, host: "10.0.0.8"),
      links: [.bluetooth, .wifi],
      addresses: [nil, "10.0.0.8"],
      checked: .bluetooth,
      target: .wifi,
      detail: .bluetooth
    ),
    RowCase(
      name: "held record keeps an empty Wi-Fi host",
      live: nil,
      peripheral: nil,
      host: "10.9.9.9",
      showsWiFi: true,
      record: heldRecord(checked: .wifi, target: nil, host: ""),
      links: [.bluetooth, .wifi],
      addresses: [nil, nil],
      checked: .wifi,
      detail: .wifi
    )
  ]

  private static func heldRecord(
    checked: TransportType,
    target: TransportType?,
    host: String
  ) -> ConnectionLinkSwitch {
    ConnectionLinkSwitch(
      radioID: radio,
      deviceID: device,
      checked: checked,
      target: target,
      token: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
      bluetoothPeripheralID: peripheral,
      wifi: ConnectionLinkWiFiDial(host: host, port: ConnectionMethod.defaultWiFiPort)
    )
  }
}

struct RowCase: Sendable, CustomTestStringConvertible {
  var name: String
  var live: TransportType?
  var peripheral: UUID?
  var host: String?
  var showsWiFi: Bool
  var record: ConnectionLinkSwitch?
  var links: [TransportType]
  var addresses: [String?]
  var checked: TransportType?
  var target: TransportType?
  var detail: ConnectionLinkRows.SettingsDetail

  var testDescription: String {
    name
  }
}
