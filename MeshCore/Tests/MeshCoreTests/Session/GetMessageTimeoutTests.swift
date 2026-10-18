import Foundation
@testable import MeshCore
import Testing

@Suite("MeshCoreSession getMessage timeout")
struct GetMessageTimeoutTests {
  @Test(arguments: [
    (defaultTimeout: 0.2, override: nil as Double?),
    (defaultTimeout: 2.0, override: 0.05),
    (defaultTimeout: 0.2, override: 0.6)
  ])
  func `getMessage uses the default timeout or its override`(
    _ timeouts: (defaultTimeout: Double, override: Double?)
  ) async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: timeouts.defaultTimeout, clientIdentifier: "MeshCore-Tests")
    )
    let startTask = Task { try await session.start() }
    try await waitUntil("transport should send appStart") {
      await transport.sentData.count == 1
    }
    await transport.simulateReceive(makeSelfInfoPacket())
    try await startTask.value

    let clock = ContinuousClock()
    let start = clock.now
    await #expect {
      _ = try await session.getMessage(timeout: timeouts.override)
    } throws: { error in
      guard let error = error as? MeshCoreError, case .timeout = error else { return false }
      return true
    }
    let elapsed = start.duration(to: clock.now)
    let expected = timeouts.override ?? timeouts.defaultTimeout
    #expect(elapsed >= .seconds(expected * 0.75))
    #expect(elapsed < .seconds(expected + 1))
    await session.stop()
  }
}

private func makeSelfInfoPacket() -> Data {
  var payload = Data([ResponseCode.selfInfo.rawValue])
  payload.append(1) // adv type
  payload.append(UInt8(bitPattern: 22)) // tx power
  payload.append(UInt8(bitPattern: 22)) // max tx power
  payload.append(Data(repeating: 0x01, count: 32)) // pubkey
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lat
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lon
  payload.append(0) // multi acks
  payload.append(0) // adv loc policy
  payload.append(0) // telemetry mode
  payload.append(0) // manual add
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(869_525).littleEndian) { Array($0) }) // freq
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(250_000).littleEndian) { Array($0) }) // bw
  payload.append(11) // sf
  payload.append(5) // cr
  return payload
}
