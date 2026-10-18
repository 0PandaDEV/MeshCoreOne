import Foundation
@testable import MeshCore
import Testing

@Suite("v1.18 session methods")
struct V118SessionMethodsTests {
  @Test
  func `runCliCommand returns UTF-8 reply`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task {
      try await session.runCliCommand("get cad")
    }

    try await waitUntil("command should be sent") {
      await transport.sentData.count == 2
    }

    let sent = await transport.sentData[1]
    #expect(sent[0] == 0x42)
    #expect(Data(sent.dropFirst()) == Data("get cad".utf8))

    var reply = Data([0x1D])
    reply.append(contentsOf: "Unknown command".utf8)
    await transport.simulateReceive(reply)

    let text = try await task.value
    #expect(text == "Unknown command")
    await session.stop()
  }

  @Test
  func `runCliCommand propagates unsupported as deviceError`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task {
      try await session.runCliCommand("get cad")
    }
    try await waitUntil("command should be sent") {
      await transport.sentData.count == 2
    }
    await transport.simulateError(code: 1)

    let err = await #expect(throws: MeshCoreError.self) {
      try await task.value
    }
    guard case let .deviceError(code)? = err else {
      Issue.record("Expected deviceError, got \(String(describing: err))")
      await session.stop()
      return
    }
    #expect(code == 1)
    await session.stop()
  }

  @Test
  func `runCliCommand rejects a one-byte command without sending`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)
    let sentAfterStart = await transport.sentData.count

    let err = await #expect(throws: MeshCoreError.self) {
      try await session.runCliCommand("x")
    }
    guard case .invalidInput? = err else {
      Issue.record("Expected invalidInput, got \(String(describing: err))")
      await session.stop()
      return
    }
    let sentCount = await transport.sentData.count
    #expect(sentCount == sentAfterStart)
    await session.stop()
  }

  @Test
  func `runCliCommand rejects empty command without sending`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)
    let sentAfterStart = await transport.sentData.count

    let err = await #expect(throws: MeshCoreError.self) {
      try await session.runCliCommand("   ")
    }
    guard case .invalidInput? = err else {
      Issue.record("Expected invalidInput, got \(String(describing: err))")
      await session.stop()
      return
    }
    let sentCount = await transport.sentData.count
    #expect(sentCount == sentAfterStart)
    await session.stop()
  }

  @Test
  func `runCliCommand rejects oversized command without sending`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)
    let sentAfterStart = await transport.sentData.count
    let oversized = String(repeating: "a", count: PacketBuilder.runCliCommandMaxUTF8Bytes + 1)

    let err = await #expect(throws: MeshCoreError.self) {
      try await session.runCliCommand(oversized)
    }
    guard case .invalidInput? = err else {
      Issue.record("Expected invalidInput, got \(String(describing: err))")
      await session.stop()
      return
    }
    let sentCount = await transport.sentData.count
    #expect(sentCount == sentAfterStart)
    await session.stop()
  }

  @Test
  func `runCliCommand sends a max-length command`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)
    let command = String(repeating: "a", count: PacketBuilder.runCliCommandMaxUTF8Bytes)

    let task = Task {
      try await session.runCliCommand(command)
    }
    try await waitUntil("command should be sent") {
      await transport.sentData.count == 2
    }
    let sent = await transport.sentData[1]
    #expect(sent.count == PacketBuilder.maxFrameSize)
    #expect(sent[0] == 0x42)
    #expect(Data(sent.dropFirst()) == Data(command.utf8))

    var reply = Data([0x1D])
    reply.append(contentsOf: "OK".utf8)
    await transport.simulateReceive(reply)
    _ = try await task.value
    await session.stop()
  }

  @Test
  func `runCliCommand sends the line verbatim`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let commands = ["set wifi.pwd ", "set wifi.ssid Field Net "]
    for (offset, command) in commands.enumerated() {
      let task = Task {
        try await session.runCliCommand(command)
      }
      let sentIndex = offset + 1
      try await waitUntil("command should be sent") {
        await transport.sentData.count == sentIndex + 1
      }
      let sent = await transport.sentData[sentIndex]
      #expect(Data(sent.dropFirst()) == Data(command.utf8))
      if offset == 0 {
        #expect(sent.last == 0x20)
      }

      var reply = Data([0x1D])
      reply.append(contentsOf: "OK".utf8)
      await transport.simulateReceive(reply)
      _ = try await task.value
    }
    await session.stop()
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
