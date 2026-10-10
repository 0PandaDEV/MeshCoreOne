import Foundation
@testable import MC1
@testable import MC1Services
import Testing

@Suite("Chat draft editor")
@MainActor
struct ChatDraftEditorTests {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "test.chat-draft-editor.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func dmID() -> ChatConversationID {
    .dm(radioID: UUID(), contactID: UUID())
  }

  private func persistedDraft(in defaults: UserDefaults, for id: ChatConversationID) -> String? {
    DraftStore(defaults: defaults).draft(for: id)
  }

  @Test
  func `lookup seeds saved text and does not schedule a write`() {
    let defaults = makeDefaults()
    let id = dmID()
    DraftStore(defaults: defaults).setDraft("saved", for: id)

    let editor = ChatDraftEditor(conversationID: id, store: DraftStore(defaults: defaults))

    #expect(editor.text == "saved")
    editor.flush()
    #expect(persistedDraft(in: defaults, for: id) == "saved")
  }

  @Test
  func `flush writes the latest edit and an intentional clear deletes it`() {
    let defaults = makeDefaults()
    let id = dmID()
    DraftStore(defaults: defaults).setDraft("old", for: id)
    let editor = ChatDraftEditor(conversationID: id, store: DraftStore(defaults: defaults))

    editor.setText("latest")
    #expect(persistedDraft(in: defaults, for: id) == "old")
    editor.flush()
    #expect(persistedDraft(in: defaults, for: id) == "latest")

    editor.setText("   \n")
    editor.flush()
    #expect(editor.text == "   \n")
    #expect(persistedDraft(in: defaults, for: id) == nil)
  }

  @Test
  func `debounce persists the latest edit and a cancelled save does not overwrite it`() async throws {
    let defaults = makeDefaults()
    let id = dmID()
    let editor = ChatDraftEditor(conversationID: id, store: DraftStore(defaults: defaults))

    editor.setText("first")
    try await Task.sleep(for: .milliseconds(100))
    editor.setText("second")

    try await waitUntil(timeout: .seconds(2), "latest edit should persist") {
      persistedDraft(in: defaults, for: id) == "second"
    }
    try await Task.sleep(for: .milliseconds(600))
    #expect(persistedDraft(in: defaults, for: id) == "second")

    editor.setText("third")
    editor.flush()
    #expect(persistedDraft(in: defaults, for: id) == "third")
    try await Task.sleep(for: .milliseconds(600))
    #expect(persistedDraft(in: defaults, for: id) == "third")
  }

  @Test
  func `repeated lookup returns one editor and another key stays isolated`() {
    let defaults = makeDefaults()
    let id = dmID()
    DraftStore(defaults: defaults).setDraft("seed", for: id)
    let appState = AppState(defaults: defaults)
    defer { appState.shutdown() }

    let first = appState.chatDraftEditor(for: id)
    let second = appState.chatDraftEditor(for: id)
    #expect(first === second)
    #expect(first.text == "seed")

    let other = ChatConversationID.channel(radioID: UUID(), channelIndex: 2)
    let isolated = appState.chatDraftEditor(for: other)
    isolated.setText("other")
    isolated.flush()

    #expect(isolated !== first)
    #expect(first.text == "seed")
    #expect(persistedDraft(in: defaults, for: id) == "seed")
    #expect(persistedDraft(in: defaults, for: other) == "other")
  }

  @Test
  func `a retired editor ignores edits and flushes`() async throws {
    let defaults = makeDefaults()
    let id = dmID()
    let editor = ChatDraftEditor(conversationID: id, store: DraftStore(defaults: defaults))

    editor.setText("live")
    editor.retire()
    try await Task.sleep(for: .milliseconds(600))
    #expect(persistedDraft(in: defaults, for: id) == nil)

    editor.setText("stale")
    editor.flush()
    #expect(editor.text == "live")
    #expect(persistedDraft(in: defaults, for: id) == nil)
  }

  @Test
  func `reset cancels a pending save and still accepts a later edit`() async throws {
    let defaults = makeDefaults()
    let id = dmID()
    DraftStore(defaults: defaults).setDraft("saved", for: id)
    let editor = ChatDraftEditor(conversationID: id, store: DraftStore(defaults: defaults))

    editor.setText("pending")
    editor.reset()
    #expect(editor.text.isEmpty)
    #expect(persistedDraft(in: defaults, for: id) == nil)

    try await Task.sleep(for: .milliseconds(600))
    #expect(persistedDraft(in: defaults, for: id) == nil)

    editor.setText("after")
    editor.flush()
    #expect(editor.text == "after")
    #expect(persistedDraft(in: defaults, for: id) == "after")
  }

  @Test
  func `backup reset clears affected slots and keeps every other draft`() async throws {
    let defaults = makeDefaults()
    let appState = AppState(defaults: defaults)
    defer { appState.shutdown() }
    let radioA = UUID()
    let radioB = UUID()
    let affected = ChatConversationID.channel(radioID: radioA, channelIndex: 1)
    let otherSlot = ChatConversationID.channel(radioID: radioA, channelIndex: 2)
    let otherRadio = ChatConversationID.channel(radioID: radioB, channelIndex: 1)
    let direct = dmID()

    let affectedEditor = appState.chatDraftEditor(for: affected)
    affectedEditor.setText("gone")
    affectedEditor.flush()
    affectedEditor.setText("pending")
    let slotEditor = appState.chatDraftEditor(for: otherSlot)
    slotEditor.setText("slot")
    slotEditor.flush()
    let radioEditor = appState.chatDraftEditor(for: otherRadio)
    radioEditor.setText("radio")
    radioEditor.flush()
    let directEditor = appState.chatDraftEditor(for: direct)
    directEditor.setText("dm")
    directEditor.flush()

    appState.resetChannelDrafts(slotsByRadio: [radioA: [1]])
    try await Task.sleep(for: .milliseconds(600))

    #expect(affectedEditor === appState.chatDraftEditor(for: affected))
    #expect(affectedEditor.text.isEmpty)
    #expect(persistedDraft(in: defaults, for: affected) == nil)
    #expect(slotEditor.text == "slot")
    #expect(persistedDraft(in: defaults, for: otherSlot) == "slot")
    #expect(radioEditor.text == "radio")
    #expect(persistedDraft(in: defaults, for: otherRadio) == "radio")
    #expect(directEditor.text == "dm")
    #expect(persistedDraft(in: defaults, for: direct) == "dm")

    affectedEditor.setText("after")
    affectedEditor.flush()
    #expect(persistedDraft(in: defaults, for: affected) == "after")
  }

  @Test
  func `shutdown flushes dirty text and retirement rejects later writes`() async throws {
    let defaults = makeDefaults()
    let appState = AppState(defaults: defaults)
    let id = dmID()
    let editor = appState.chatDraftEditor(for: id)
    editor.setText("dirty")

    appState.shutdown()

    #expect(persistedDraft(in: defaults, for: id) == "dirty")
    editor.setText("after")
    editor.flush()
    #expect(editor.text == "dirty")
    #expect(persistedDraft(in: defaults, for: id) == "dirty")
    try await Task.sleep(for: .milliseconds(600))
    #expect(persistedDraft(in: defaults, for: id) == "dirty")
  }

  @Test
  func `session teardown keeps the same editor and its live text`() {
    let defaults = makeDefaults()
    let appState = AppState(defaults: defaults)
    defer { appState.shutdown() }
    let id = dmID()
    let editor = appState.chatDraftEditor(for: id)
    editor.setText("live")

    appState.tearDownAppStateSessionState()

    let again = appState.chatDraftEditor(for: id)
    #expect(again === editor)
    #expect(again.text == "live")
  }
}
