@testable import MC1
@testable import MC1Services
import Testing

@Suite("StatusPillState Tests")
struct StatusPillStateTests {
  @Test
  @MainActor
  func `Failed state takes highest priority`() {
    let appState = AppState()
    appState.connectionUI.showSyncFailedPill()
    #expect(appState.statusPillState == .failed(message: "Sync Failed"))
  }

  @Test
  @MainActor
  func `Syncing takes priority over connecting`() {
    let appState = AppState()
    appState.connectionUI.simulateSyncStarted()
    #expect(appState.statusPillState == .syncing)
    appState.connectionUI.simulateSyncEnded()
  }

  @Test
  @MainActor
  func `Ready state shows when toast is active and connection is usable`() {
    let appState = AppState()
    appState.connectionManager.setTestState(connectionState: .ready)
    appState.connectionUI.showReadyToastBriefly()
    #expect(appState.statusPillState == .ready)
  }

  @Test
  @MainActor
  func `Hidden when no conditions met`() {
    let appState = AppState()
    #expect(appState.statusPillState == .hidden)
  }
}
