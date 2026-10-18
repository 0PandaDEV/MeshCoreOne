import Foundation
@testable import MC1Services
import Testing

/// The device picker dials `DeviceDTO.savedDeviceConnectTarget`.
@Suite("Device selection sheet transport")
struct DeviceSelectionSheetTests {
  @Test
  func `bluetooth then wifi dials wifi`() {
    let device = DeviceDTO.testDevice().copy {
      $0.connectionMethods = [
        .bluetooth(peripheralUUID: UUID(), displayName: nil),
        .wifi(host: "10.0.0.4", port: 5000, displayName: nil)
      ]
    }
    #expect(device.savedDeviceConnectTarget == .wifi(host: "10.0.0.4", port: 5000))
  }

  @Test
  func `wifi then bluetooth dials the peripheral and the id is that peripheral`() {
    let peripheralID = UUID()
    let device = DeviceDTO.testDevice(id: peripheralID).copy {
      $0.connectionMethods = [
        .wifi(host: "10.0.0.4", port: 5000, displayName: nil),
        .bluetooth(peripheralUUID: peripheralID, displayName: nil)
      ]
    }
    #expect(device.id == peripheralID)
    #expect(device.savedDeviceConnectTarget == .bluetooth(peripheralID: peripheralID))
  }

  @Test
  func `wifi only dials wifi`() {
    let device = DeviceDTO.testDevice().copy {
      $0.connectionMethods = [.wifi(host: "10.1.1.1", port: 5000, displayName: nil)]
    }
    #expect(device.savedDeviceConnectTarget == .wifi(host: "10.1.1.1", port: 5000))
  }

  @Test
  func `no methods dials the device id`() {
    let device = DeviceDTO.testDevice()
    #expect(device.connectionMethods.isEmpty)
    #expect(device.savedDeviceConnectTarget == .bluetooth(peripheralID: device.id))
  }
}
