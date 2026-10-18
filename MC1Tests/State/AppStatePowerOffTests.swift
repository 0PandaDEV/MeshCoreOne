import Foundation
@testable import MC1
@testable import MC1Services
@testable import MeshCore
import Testing

@Suite("AppState power off")
@MainActor
struct AppStatePowerOffTests {
  @Test
  func `a reply leaves the radio connected`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    let appState = try await makeAppState(session: session)
    defer { appState.shutdown() }
    try await startSession(session, transport: transport)
    defer { Task { await session.stop() } }

    let task = Task { try await appState.powerOffRadio() }
    try await waitUntil("poweroff should be sent") {
      await transport.sentData.count == 2
    }
    let sent = await transport.sentData[1]
    #expect(sent.first == 0x42)
    #expect(Data(sent.dropFirst()) == Data(PacketBuilder.powerOffCommand.utf8))
    await transport.simulateReceive(Data([ResponseCode.cliReply.rawValue]))

    do {
      try await task.value
      Issue.record("expected powerOffUnsupported")
    } catch let error as SettingsServiceError {
      guard case .powerOffUnsupported = error else {
        Issue.record("expected powerOffUnsupported, got \(error)")
        return
      }
    } catch {
      Issue.record("expected SettingsServiceError, got \(error)")
    }

    #expect(appState.connectionManager.connectionIntent.wantsConnection)
    #expect(appState.connectionState == .ready)
  }

  @Test
  func `silence disconnects as a user power off`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    let appState = try await makeAppState(session: session)
    defer { appState.shutdown() }
    try await startSession(session, transport: transport)

    try await appState.powerOffRadio()

    #expect(appState.connectionManager.connectionIntent.isUserDisconnected)
    #expect(appState.connectionState == .disconnected)
  }

  @Test
  func `a replacement connection survives a power off that was already waiting`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    let appState = try await makeAppState(session: session)
    defer { appState.shutdown() }
    try await startSession(session, transport: transport)

    await transport.holdNextSend()
    let task = Task { try await appState.powerOffRadio() }
    try await waitUntil("poweroff write should park") { await transport.sendIsWaiting }

    let replacementTransport = MockTransport()
    let replacement = MeshCoreSession(transport: replacementTransport)
    let replacementDevice = makeDevice(firmwareVersion: 14)
    let replacementServices = try await ServiceContainer.forTesting(session: replacement)
    appState.connectionManager.setTestState(
      connectionState: .ready,
      services: replacementServices,
      session: replacement,
      connectedDevice: replacementDevice,
      connectionIntent: .wantsConnection()
    )
    await transport.failHeldSend()
    await transport.releaseHeldSend()

    await #expect(throws: PowerOffSuperseded.self) { try await task.value }
    #expect(appState.connectionManager.session === replacement)
    #expect(appState.connectionManager.connectionIntent.wantsConnection)
    #expect(appState.connectionState == .ready)
    #expect(appState.connectionManager.connectedDevice?.id == replacementDevice.id)
  }

  private func makeAppState(session: MeshCoreSession) async throws -> AppState {
    let suite = "test.poweroff.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let appState = try AppState(
      modelContainer: PersistenceStore.createContainer(inMemory: true),
      isPlaceholder: true,
      defaults: defaults
    )
    let services = try await ServiceContainer.forTesting(session: session)
    appState.connectionManager.setTestState(
      connectionState: .ready,
      services: services,
      session: session,
      connectedDevice: makeDevice(firmwareVersion: 14),
      connectionIntent: .wantsConnection()
    )
    return appState
  }

  private func makeDevice(firmwareVersion: UInt8) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: 0x01, count: 32),
      nodeName: "TestDevice",
      firmwareVersion: firmwareVersion,
      firmwareVersionString: "1.18.0",
      manufacturerName: "Test",
      buildDate: "",
      maxContacts: 100,
      maxChannels: 16,
      frequency: 869_525,
      bandwidth: 250_000,
      spreadingFactor: 11,
      codingRate: 5,
      txPower: 20,
      maxTxPower: 22,
      latitude: 0,
      longitude: 0,
      blePin: 0,
      clientRepeat: false,
      pathHashMode: 0,
      manualAddContacts: false,
      autoAddConfig: 0,
      autoAddMaxHops: 0,
      multiAcks: 0,
      telemetryModeBase: 0,
      telemetryModeLoc: 0,
      telemetryModeEnv: 0,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: true,
      ocvPreset: nil,
      customOCVArrayString: nil,
      connectionMethods: []
    )
  }
}

private func startSession(
  _ session: MeshCoreSession,
  transport: MockTransport
) async throws {
  let startTask = Task { try await session.start() }
  try await waitUntil("transport should send appStart before session starts") {
    await transport.sentData.count == 1
  }
  await transport.simulateReceive(makeSelfInfoPacket())
  try await startTask.value
}

private func makeSelfInfoPacket() -> Data {
  var payload = Data([ResponseCode.selfInfo.rawValue])
  payload.append(1)
  payload.append(UInt8(bitPattern: 22))
  payload.append(UInt8(bitPattern: 22))
  payload.append(Data(repeating: 0x01, count: 32))
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) })
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) })
  payload.append(0)
  payload.append(0)
  payload.append(0)
  payload.append(0)
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(869_525).littleEndian) { Array($0) })
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(250_000).littleEndian) { Array($0) })
  payload.append(11)
  payload.append(5)
  return payload
}
