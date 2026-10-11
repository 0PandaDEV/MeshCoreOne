import Foundation
@testable import MC1
@testable import MC1Services
import MeshCore
import Testing

@Suite("Connection status lifecycle", .serialized)
@MainActor
struct ConnectionStatusLifecycleTests {
  private func makeAppState(clock: TestClock? = nil) throws -> AppState {
    try AppState(
      modelContainer: PersistenceStore.createContainer(inMemory: true),
      isPlaceholder: true,
      injectedConnectionUI: ConnectionUIState(clock: clock)
    )
  }

  private func wireConnection(_ appState: AppState) async throws -> ServiceContainer {
    let services = try await ServiceContainer.forTesting(
      session: MeshCoreSession(transport: MockTransport())
    )
    appState.connectionManager.setTestState(connectionState: .connected, services: services)
    await appState.wireServicesIfConnected()
    return services
  }

  @Test(arguments: [DeviceConnectionState.connected, .syncing], [false, true])
  func `catch-up stays visible until polling returns and Ready waits for usability`(
    connectionState: DeviceConnectionState,
    pollingFails: Bool
  ) async throws {
    let appState = try makeAppState()
    defer { appState.shutdown() }
    let services = try await wireConnection(appState)
    appState.connectionManager.setTestState(connectionState: connectionState)
    let poller = SuspendedMessagePoller()
    let sync = Task {
      try await services.syncCoordinator.performFullSync(
        radioID: UUID(),
        dataStore: services.dataStore,
        contactService: EmptyContacts(),
        channelService: EmptyChannels(),
        messagePollingService: poller
      )
    }
    try await waitUntil("message polling should suspend") { await poller.isWaiting }

    #expect(appState.connectionUI.syncActivityCount == 0)
    #expect(appState.statusPillState == .syncingMessages)
    #expect(!appState.connectionUI.showReadyToast)

    await poller.finish(failing: pollingFails)
    let result = try await sync.value
    #expect(result.isConnectionUsable)
    if pollingFails {
      #expect(result.messages == .failed(SyncCoordinatorError.syncFailed("Message catch-up failed").localizedDescription))
    } else {
      #expect(result.messages == .clean)
    }
    #expect(appState.connectionUI.currentSyncPhase == nil)
    #expect(appState.statusPillState == .syncing)
    #expect(!appState.connectionUI.showReadyToast)
    #expect(!appState.connectionUI.syncFailedPillVisible)

    appState.connectionManager.setTestState(connectionState: .ready)
    #expect(appState.statusPillState == .ready)
  }

  @Test
  func `duplicate Ready assignments do not restart the toast and live messages stay quiet`() async throws {
    let clock = TestClock()
    let appState = try makeAppState(clock: clock)
    defer { appState.shutdown() }
    let services = try await wireConnection(appState)
    appState.connectionManager.setTestState(connectionState: .ready)
    try await waitUntil("Ready timer should park") { clock.sleeperCount == 1 }
    clock.advance(by: .seconds(1))
    appState.connectionManager.setTestState(connectionState: .ready)
    clock.advance(by: .seconds(1))
    try await waitUntil("Ready should expire without restarting") { !appState.connectionUI.showReadyToast }
    #expect(appState.statusPillState == .hidden)

    services.syncCoordinator.notifyConversationsChanged()
    #expect(appState.statusPillState == .hidden)
    services.syncCoordinator.setState(.syncing(progress: SyncProgress(phase: .messages, current: 0, total: 0)))
    #expect(appState.statusPillState == .hidden)
  }

  @Test
  func `Ready remains visible over overlapping activity then activity resumes its pill`() async throws {
    let clock = TestClock()
    let appState = try makeAppState(clock: clock)
    defer { appState.shutdown() }
    let services = try await wireConnection(appState)
    appState.connectionManager.setTestState(connectionState: .ready)
    try await waitUntil("Ready timer should park") { clock.sleeperCount == 1 }
    await services.syncCoordinator.beginResyncActivity()
    await services.syncCoordinator.beginResyncActivity()
    #expect(appState.statusPillState == .ready)

    clock.advance(by: .seconds(2))
    try await waitUntil("Ready should expire") { !appState.connectionUI.showReadyToast }
    #expect(appState.statusPillState == .syncing)
    await services.syncCoordinator.endResyncActivity(succeeded: false)
    #expect(appState.statusPillState == .syncing)
    await services.syncCoordinator.endResyncActivity(succeeded: true)
    #expect(appState.connectionUI.syncActivityCount == 0)
    #expect(appState.statusPillState == .ready)
  }

  @Test
  func `failure wins over catch-up and unusable connections cannot display a stale Ready toast`() async throws {
    let appState = try makeAppState()
    defer { appState.shutdown() }
    let services = try await wireConnection(appState)
    appState.connectionUI.showReadyToastBriefly()
    services.syncCoordinator.setState(.syncing(progress: SyncProgress(phase: .messages, current: 0, total: 0)))
    #expect(appState.statusPillState == .syncingMessages)
    appState.connectionManager.onResyncFailed?()
    #expect(appState.statusPillState == .failed(message: L10n.Localizable.StatusPill.syncFailed))
    appState.connectionUI.hideSyncFailedPill()
    appState.connectionManager.setTestState(connectionState: .connecting)
    #expect(appState.statusPillState == .connecting)
    appState.connectionManager.setTestState(connectionState: .disconnected)
    #expect(appState.statusPillState == .hidden)
  }

  @Test
  func `replacement resets sync UI and fences callbacks from the previous coordinator`() async throws {
    let clock = TestClock()
    let appState = try makeAppState(clock: clock)
    defer { appState.shutdown() }
    let oldServices = try await wireConnection(appState)
    await oldServices.syncCoordinator.beginResyncActivity()
    oldServices.syncCoordinator.setState(.syncing(progress: SyncProgress(phase: .messages, current: 0, total: 0)))
    appState.connectionUI.showReadyToastBriefly()
    try await waitUntil("old Ready timer should park") { clock.sleeperCount == 1 }

    let newServices = try await wireConnection(appState)
    #expect(appState.syncCoordinator === newServices.syncCoordinator)
    #expect(appState.connectionUI.syncActivityCount == 0)
    #expect(appState.connectionUI.currentSyncPhase == nil)
    #expect(!appState.connectionUI.showReadyToast)
    await newServices.syncCoordinator.beginResyncActivity()
    await oldServices.syncCoordinator.beginResyncActivity()
    await oldServices.syncCoordinator.endResyncActivity(succeeded: true)
    oldServices.syncCoordinator.setState(.syncing(progress: SyncProgress(phase: .messages, current: 0, total: 0)))
    #expect(appState.connectionUI.syncActivityCount == 1)
    #expect(appState.connectionUI.currentSyncPhase == nil)

    appState.connectionManager.setTestState(connectionState: .ready)
    try await waitUntil("new Ready timer should replace the old one") { clock.sleeperCount == 1 }
    clock.advance(by: .seconds(1))
    await appState.wireServicesIfConnected()
    #expect(appState.connectionUI.syncActivityCount == 1)
    #expect(appState.statusPillState == .ready)
    clock.advance(by: .seconds(1))
    try await waitUntil("same coordinator wiring must not restart Ready") { !appState.connectionUI.showReadyToast }
    #expect(appState.statusPillState == .syncing)
  }

  @Test
  func `disconnect clears catch-up and ignores late activity and phase callbacks`() async throws {
    let appState = try makeAppState()
    defer { appState.shutdown() }
    let services = try await wireConnection(appState)
    await services.syncCoordinator.beginResyncActivity()
    services.syncCoordinator.setState(.syncing(progress: SyncProgress(phase: .messages, current: 0, total: 0)))
    appState.connectionManager.setTestState(connectionState: .disconnected, services: .some(nil))
    await appState.wireServicesIfConnected()
    await services.syncCoordinator.endResyncActivity(succeeded: true)
    await services.syncCoordinator.beginResyncActivity()
    services.syncCoordinator.setState(.syncing(progress: SyncProgress(phase: .messages, current: 0, total: 0)))
    #expect(appState.connectionUI.syncActivityCount == 0)
    #expect(appState.connectionUI.currentSyncPhase == nil)
    #expect(!appState.connectionUI.showReadyToast)
    #expect(appState.statusPillState != .ready)
    #expect(appState.statusPillState != .syncingMessages)
  }

  private actor EmptyContacts: ContactServiceProtocol {
    func syncContacts(radioID: UUID, since: Date?) async throws -> ContactSyncResult {
      ContactSyncResult(contactsReceived: 0, lastSyncTimestamp: 0, isIncremental: false)
    }
  }

  private actor EmptyChannels: ChannelServiceProtocol {
    func syncChannels(radioID: UUID, maxChannels: UInt8, usePipelinedRead: Bool) async throws -> ChannelSyncResult {
      ChannelSyncResult(channelsSynced: 0, errors: [])
    }

    func retryFailedChannels(radioID: UUID, indices: [UInt8]) async throws -> ChannelSyncResult {
      ChannelSyncResult(channelsSynced: 0, errors: [])
    }
  }

  private actor SuspendedMessagePoller: MessagePollingServiceProtocol {
    private var continuation: CheckedContinuation<Int, any Error>?
    var isWaiting: Bool {
      continuation != nil
    }

    func pollAllMessages() async throws -> Int {
      try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(failing: Bool) {
      let pending = continuation
      continuation = nil
      if failing {
        pending?.resume(throwing: SyncCoordinatorError.syncFailed("Message catch-up failed"))
      } else {
        pending?.resume(returning: 0)
      }
    }

    func waitForPendingHandlers(timeout: Duration) async -> Bool {
      true
    }

    func startAutoFetch(radioID: UUID) async {}
    func pauseAutoFetch() async {}
    func resumeAutoFetch() async {}
    func setContactMessageHandler(_ handler: @escaping @Sendable (ContactMessage, ContactDTO?, DeliveryContext) async -> Void) {}
    func setChannelMessageHandler(_ handler: @escaping @Sendable (ChannelMessage, ChannelDTO?, DeliveryContext) async -> Void) {}
    func setSignedMessageHandler(_ handler: @escaping @Sendable (ContactMessage, ContactDTO?) async -> Void) {}
    func setCLIMessageHandler(_ handler: @escaping @Sendable (ContactMessage, ContactDTO?) async -> Void) {}
  }
}
