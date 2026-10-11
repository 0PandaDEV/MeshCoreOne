import Foundation
@testable import MC1
@testable import MC1Services
import Testing

@Suite("ChatViewModel read state")
@MainActor
struct ChatViewModelReadStateTests {
  @Test
  func `read and unread work offline and refresh the unread filter`() async throws {
    let environment = try await makeEnvironment()
    let viewModel = environment.viewModel
    let captured = environment.contact
    #expect(viewModel.notificationService == nil)

    await viewModel.setReadState(.direct(captured), isRead: true)
    await viewModel.setReadState(.channel(environment.channel), isRead: true)
    await viewModel.setReadState(.room(environment.room), isRead: true)

    #expect(viewModel.liveConversation(id: captured.id)?.unreadCount == 0)
    #expect(viewModel.liveConversation(id: environment.channel.id)?.unreadCount == 0)
    #expect(viewModel.liveConversation(id: environment.room.id)?.unreadCount == 0)
    #expect(viewModel.allConversations.filtered(by: .unread, searchText: "").isEmpty)
    #expect(viewModel.errorMessage == nil)

    // The held DTO is still unread; the menu's explicit intent must win.
    await viewModel.setReadState(.direct(captured), isRead: false)

    #expect(viewModel.liveConversation(id: captured.id)?.unreadCount == 1)
    #expect(viewModel.allConversations.filtered(by: .unread, searchText: "").map(\.id) == [captured.id])
    #expect(viewModel.errorMessage == nil)
  }

  @Test
  func `missing store surfaces an error without changing the list`() async throws {
    let environment = try await makeEnvironment()
    let viewModel = environment.viewModel
    viewModel.configureForTesting(dependencies: .testDefaults(currentRadioID: { environment.radioID }))

    await viewModel.setReadState(.direct(environment.contact), isRead: true)

    #expect(viewModel.errorMessage == L10n.Chats.Chats.Error.readStateSaveFailed)
    #expect(viewModel.liveConversation(id: environment.contact.id)?.unreadCount == 4)
  }

  @Test
  func `missing row surfaces an error`() async throws {
    let environment = try await makeEnvironment()
    try await environment.store.deleteContact(id: environment.contact.id)

    await environment.viewModel.setReadState(.direct(environment.contact), isRead: true)

    #expect(environment.viewModel.errorMessage == L10n.Chats.Chats.Error.readStateSaveFailed)
    #expect(environment.viewModel.liveConversation(id: environment.contact.id)?.unreadCount == 4)
  }

  @Test
  func `read cancels a stale reload so unread state cannot reappear`() async throws {
    let environment = try await makeEnvironment()
    let viewModel = environment.viewModel
    let arrived = Gate()
    let resume = Gate()
    viewModel.reloadInterleaveHook = {
      await arrived.open()
      await resume.wait()
    }
    let staleReload = viewModel.requestConversationReload()
    await arrived.wait()
    viewModel.reloadInterleaveHook = nil

    await viewModel.setReadState(.direct(environment.contact), isRead: true)
    await resume.open()
    await staleReload?.value

    #expect(viewModel.liveConversation(id: environment.contact.id)?.unreadCount == 0)
    #expect(try await environment.store.fetchContact(id: environment.contact.id)?.unreadCount == 0)
  }

  @Test
  func `opening a marked unread DM clears the reminder offline`() async throws {
    let environment = try await makeEnvironment()
    let viewModel = environment.viewModel
    await viewModel.setReadState(.direct(environment.contact), isRead: true)
    await viewModel.setReadState(.direct(environment.contact), isRead: false)
    viewModel.bindCoordinatorForTesting(ChatCoordinator.makeForTesting())

    await viewModel.loadMessages(for: environment.contact, populateMode: .replace)

    #expect(try await environment.store.fetchContact(id: environment.contact.id)?.unreadCount == 0)
  }

  private struct Environment {
    let store: PersistenceStore
    let radioID: UUID
    let viewModel: ChatViewModel
    let contact: ContactDTO
    let channel: ChannelDTO
    let room: RemoteNodeSessionDTO
  }

  private func makeEnvironment() async throws -> Environment {
    let store = try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
    let radioID = UUID()
    let contact = ContactDTO(
      id: UUID(), radioID: radioID, publicKey: Data(repeating: 0xAB, count: 32), name: "Ada",
      typeRawValue: ContactType.chat.rawValue, flags: 0, outPathLength: 0, outPath: Data(),
      lastAdvertTimestamp: 0, latitude: 0, longitude: 0, lastModified: 0, lastHeardTimestamp: nil,
      nickname: nil, isBlocked: false, isMuted: false, isFavorite: false,
      lastMessageDate: Date(), unreadCount: 4, unreadMentionCount: 2
    )
    let channel = ChannelDTO(
      id: UUID(), radioID: radioID, index: 1, name: "General", secret: Data(), isEnabled: true,
      lastMessageDate: Date(), unreadCount: 4, unreadMentionCount: 2
    )
    let room = RemoteNodeSessionDTO(
      id: UUID(), radioID: radioID, publicKey: Data(repeating: 0xCC, count: 32), name: "Room",
      role: .roomServer, isConnected: false, unreadCount: 4, lastMessageDate: Date()
    )
    try await store.saveContact(contact)
    try await store.saveChannel(channel)
    try await store.saveRemoteNodeSessionDTO(room)
    let viewModel = ChatViewModel()
    viewModel.configureForTesting(dependencies: .testDefaults(
      dataStore: { store }, currentRadioID: { radioID }
    ))
    await viewModel.requestConversationReload()?.value
    return Environment(store: store, radioID: radioID, viewModel: viewModel, contact: contact, channel: channel, room: room)
  }

  private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { waiter = $0 }
    }

    func open() {
      isOpen = true
      waiter?.resume()
      waiter = nil
    }
  }
}
