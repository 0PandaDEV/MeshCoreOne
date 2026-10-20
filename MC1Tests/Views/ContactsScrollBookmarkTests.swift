@testable import MC1
@testable import MC1Services
import Observation
import SwiftUI
import Testing
import UIKit

@Suite("Nodes scroll bookmark", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ContactsScrollBookmarkTests {
  private enum Layout {
    static let compactSize = CGSize(width: 390, height: 844)
    static let contactCount = 300
    static let restoredContactIndex = 200
    static let longNameInterval = 3
    static let advertInterval: UInt32 = 60
    static let topTolerance: CGFloat = 1
    static let pollInterval: Duration = .milliseconds(100)
    static let waitTimeout: Duration = .seconds(6)
    static let scrollSettle: Duration = .milliseconds(500)
  }

  @Test
  func `reaching the actual top clears the retained bookmark`() async throws {
    let fixture = try makeFixture()
    defer { fixture.tearDown() }
    try #require(await waitFor {
      guard let scroll = scrollView(in: fixture.window) else { return false }
      return topOffset(scroll) > fixture.window.bounds.height
    })
    let scroll = try #require(scrollView(in: fixture.window))
    scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
    try #require(await waitFor { fixture.state.scrollPositionID == nil })
    fixture.render.status = "Updated ancestor"
    try await Task.sleep(for: Layout.scrollSettle)
    #expect(abs(topOffset(scroll)) < Layout.topTolerance)
  }

  private func scrollView(in window: UIWindow) -> UIScrollView? {
    views(window).compactMap { $0 as? UIScrollView }.first { $0.contentSize.height > window.bounds.height }
  }

  private func topOffset(_ scroll: UIScrollView) -> CGFloat {
    scroll.contentOffset.y + scroll.adjustedContentInset.top
  }

  private func views(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { views($0) }
  }

  private func waitFor(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + Layout.waitTimeout
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: Layout.pollInterval)
    }
    return condition()
  }

  private func makeFixture() throws -> Fixture {
    let radioID = UUID()
    let now = UInt32(Date().timeIntervalSince1970)
    let model = ContactsViewModel()
    model.contacts = (0..<Layout.contactCount).map { index in
      contact(index: index, radioID: radioID, timestamp: now - UInt32(index + 1) * Layout.advertInterval)
    }
    model.hasLoadedOnce = true
    let state = ContactsSidebarState(viewModel: model)
    state.scrollPositionID = model.contacts[Layout.restoredContactIndex].id
    let render = RenderState()
    let container = try PersistenceStore.createContainer(inMemory: true)
    let appState = AppState(modelContainer: container, isPlaceholder: true)
    let suiteName = "ContactsScrollBookmarkTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(NodeSortOrder.lastHeard.rawValue, forKey: AppStorageKey.nodesSortOrder.rawValue)
    let root = Host(state: state, render: render).environment(\.appState, appState).defaultAppStorage(defaults)
    let controller = UIHostingController(rootView: root)
    controller.traitOverrides.horizontalSizeClass = .compact
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: Layout.compactSize)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    return Fixture(
      state: state, render: render, appState: appState,
      defaults: defaults, suiteName: suiteName, window: window
    )
  }

  private func contact(index: Int, radioID: UUID, timestamp: UInt32) -> ContactDTO {
    let prefix = withUnsafeBytes(of: index.bigEndian) { Data($0) }
    let publicKey = prefix + Data(repeating: 0, count: ProtocolLimits.publicKeySize - prefix.count)
    return ContactDTO(
      id: UUID(), radioID: radioID, publicKey: publicKey,
      name: index.isMultiple(of: Layout.longNameInterval)
        ? "Contact \(index) with a longer name that wraps onto another line" : "Contact \(index)",
      typeRawValue: ContactType.chat.rawValue, flags: 0, outPathLength: 0, outPath: Data(),
      lastAdvertTimestamp: timestamp, latitude: 0, longitude: 0, lastModified: 0,
      lastHeardTimestamp: nil, nickname: nil, isBlocked: false, isMuted: false,
      isFavorite: false, lastMessageDate: nil, unreadCount: 0
    )
  }

  @MainActor
  private struct Fixture {
    let state: ContactsSidebarState
    let render: RenderState
    let appState: AppState
    let defaults: UserDefaults
    let suiteName: String
    let window: UIWindow

    func tearDown() {
      state.end()
      window.isHidden = true
      window.rootViewController = nil
      window.windowScene = nil
      appState.shutdown()
      defaults.removePersistentDomain(forName: suiteName)
    }
  }

  @Observable
  @MainActor
  final class RenderState {
    var status = "Initial ancestor"
  }

  private struct Host: View {
    let state: ContactsSidebarState
    let render: RenderState
    var body: some View {
      NavigationStack {
        ContactsContentColumn(state: state, blockedContactsRoute: nil, rendererRevision: 0)
      }
      .overlay(alignment: .bottom) { Text(render.status).allowsHitTesting(false) }
    }
  }
}
