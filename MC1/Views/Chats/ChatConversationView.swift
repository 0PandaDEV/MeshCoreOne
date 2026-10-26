import MC1Services
import OSLog
import SwiftUI
import Translation
import UIKit // UIPasteboard for .copy action

private let logger = Logger(subsystem: "com.mc1", category: "ChatConversationView")

// MARK: - Reaction Palette Tuning

/// Number of recent emojis shown directly in the context menu's palette row;
/// the rest are reachable through "More" (the full emoji picker).
private let quickReactionCount = 3
private let reactionPaletteCellSize: CGFloat = 24
private let emojiPaletteGlyphSize: CGFloat = 14
private let morePaletteSymbolSize: CGFloat = 17
private let moreEmojiSymbol = "face.smiling"

/// Unified chat conversation view supporting both DMs and Channels.
struct ChatConversationView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.linkPreviewCache) private var linkPreviewCache
  @Environment(\.scenePhase) private var scenePhase

  @State private var conversationType: ChatConversationType
  let draftEditor: ChatDraftEditor
  let parentViewModel: ChatViewModel?

  @State private var chatViewModel: ChatViewModel

  // MARK: - Scroll State

  @State private var isAtBottom = true
  @State private var unreadCount = 0
  @State private var scrollToBottomRequest = 0
  /// Request an item-ID scroll to scrollToTargetID for a deeplink or new-messages divider.
  @State private var scrollToTargetRequest = 0
  @State private var scrollToTargetID: UUID?

  /// `AppState.channelSlotGenerations` value for this channel slot when the view
  /// appeared; a higher value later means a different channel now owns the slot.
  @State private var slotGenerationOnAppear: Int?
  /// False until the first load finishes so a reaction-scroll request stays
  /// pending until the timeline can honor it.
  @State private var didCompleteInitialLoad = false

  // MARK: - Sheet State

  @State private var showingInfo = false
  @State private var channelInfoTask: Task<Void, Never>?
  @State private var selectedMessageForInfo: MessageDTO?
  @State private var emojiPickerMessage: MessageDTO?
  @State private var blockSenderContext: BlockSenderContext?
  @State private var sendDMContext: SendDMContext?
  @State private var imageViewerData: ImageViewerData?
  @State private var translationConfiguration: TranslationSession.Configuration?
  @State private var systemTranslationText = ""
  @State private var showSystemTranslation = false

  // MARK: - Other State

  @State private var recentEmojisStore = RecentEmojisStore()
  @State private var mentionSenderOrder: [String: UInt32]?
  /// Focus-request token: each increment asks the composer to raise the
  /// keyboard once. See `ChatComposerTextView` for why a token, not `@FocusState`.
  @State private var inputFocusRequest = 0

  // MARK: - AppStorage

  @AppStorage(AppStorageKey.autoPlayGIFs.rawValue) private var autoPlayGIFs = AppStorageKey.defaultAutoPlayGIFs
  @AppStorage(AppStorageKey.showIncomingPath.rawValue) private var showIncomingPath = AppStorageKey.defaultShowIncomingPath
  @AppStorage(AppStorageKey.showIncomingHopCount.rawValue) private var showIncomingHopCount = AppStorageKey.defaultShowIncomingHopCount
  @AppStorage(AppStorageKey.showIncomingRegion.rawValue) private var showIncomingRegion = AppStorageKey.defaultShowIncomingRegion
  @AppStorage(AppStorageKey.showIncomingHeardCount.rawValue)
  private var showIncomingHeardCount = AppStorageKey.defaultShowIncomingHeardCount
  @AppStorage(AppStorageKey.showIncomingSendTime.rawValue) private var showIncomingSendTime = AppStorageKey.defaultShowIncomingSendTime
  @AppStorage(AppStorageKey.linkPreviewsEnabled.rawValue) private var previewsEnabled = AppStorageKey.defaultLinkPreviewsEnabled
  @AppStorage(AppStorageKey.replyWithQuote.rawValue) private var replyWithQuote = AppStorageKey.defaultReplyWithQuote
  @AppStorage(AppStorageKey.showMapPreviewThumbnails.rawValue) private var showMapPreviewThumbnails = AppStorageKey.defaultShowMapPreviewThumbnails
  @AppStorage(AppStorageKey.translationTargetLanguage.rawValue)
  private var translationTargetLanguage = AppStorageKey.defaultTranslationTargetLanguage
  @AppStorage(AppStorageKey.useDefaultTranslationApp.rawValue)
  private var useDefaultTranslationApp = AppStorageKey.defaultUseDefaultTranslationApp
  @AppStorage(AppStorageKey.translationOffersEnabled.rawValue)
  private var translationOffersEnabled = AppStorageKey.defaultTranslationOffersEnabled

  // MARK: - Environment

  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.mapColorSchemePreference) private var mapColorSchemePreference
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.appTheme) private var theme
  @Environment(\.locale) private var locale

  /// Capture observed settings and environment values for constructing MessageItems.
  /// Equatable changes trigger ChatConversationMessagesContent to rebuild items while the chat is open.
  private var currentEnvInputs: EnvInputs {
    EnvInputs(
      autoPlayGIFs: autoPlayGIFs,
      showIncomingPath: showIncomingPath,
      showIncomingHopCount: showIncomingHopCount,
      showIncomingRegion: showIncomingRegion,
      showIncomingHeardCount: showIncomingHeardCount,
      showIncomingSendTime: showIncomingSendTime,
      previewsEnabled: previewsEnabled,
      isHighContrast: colorSchemeContrast == .increased,
      isDark: colorScheme == .dark,
      mapBasemapIsDark: resolvedMapIsDark(
        preference: mapColorSchemePreference,
        colorScheme: colorScheme
      ),
      showMapPreviews: showMapPreviewThumbnails && !conversationType.suppressesMapPreviews,
      isOffline: !appState.networkMonitor.isNetworkAvailable,
      currentUserName: appState.localNodeName,
      themeID: theme.id,
      contentSizeCategory: AppearanceToken.contentSizeCategoryToken(dynamicTypeSize),
      preferredLanguageCode: TranslationTargetPreference(rawValue: translationTargetLanguage)
        .resolvedLanguageCode(appLocale: locale),
      translationOffersEnabled: translationOffersEnabled
    )
  }

  // MARK: - Init

  init(
    conversationType: ChatConversationType,
    draftEditor: ChatDraftEditor,
    parentViewModel: ChatViewModel? = nil,
    coordinatorRegistry: ChatCoordinatorRegistry? = nil
  ) {
    _conversationType = State(initialValue: conversationType)
    self.draftEditor = draftEditor
    self.parentViewModel = parentViewModel

    // Attach the shared coordinator before the first render so warm opens immediately show their messages.
    // configure installs the rebuild hooks when the load task binds the coordinator.
    let viewModel = ChatViewModel()
    if let coordinatorRegistry {
      viewModel.attachCoordinator(coordinatorRegistry.coordinator(for: conversationType.coordinatorID))
    }
    // Stage the anchor before rendering because warm coordinator items can appear in the first frame.
    viewModel.timeline.stageOpen(conversationType)
    _chatViewModel = State(initialValue: viewModel)
  }

  private var composingText: Binding<String> {
    Binding(
      get: { draftEditor.text },
      set: { draftEditor.setText($0) }
    )
  }

  // MARK: - Body

  @ViewBuilder
  private var titleAvatar: some View {
    switch conversationType {
    case let .dm(contact):
      ContactAvatar(contact: contact, size: 30)
    case let .channel(channel):
      ChannelAvatar(channel: channel, size: 30)
    }
  }

  var body: some View {
    ChatConversationMessagesContent(
      conversationType: conversationType,
      viewModel: chatViewModel,
      deviceName: appState.localNodeName,
      recentEmojisStore: recentEmojisStore,
      envInputs: currentEnvInputs,
      isAtBottom: $isAtBottom,
      unreadCount: $unreadCount,
      scrollToBottomRequest: scrollToBottomRequest,
      scrollToTargetRequest: scrollToTargetRequest,
      scrollToTargetID: scrollToTargetID,
      firstSnapshotDecision: chatViewModel.timeline.firstSnapshot,
      onDividerTargetConsumed: { chatViewModel.timeline.consumeAnchor() },
      imageViewerData: $imageViewerData,
      onRetryMessage: { retryMessage($0) },
      makeActionsMenu: { AnyView(messageContextMenu(for: $0)) },
      onTranslationAction: { handleInBubbleTranslation(for: $0) }
    )
    .mentionTapHandling(
      contacts: chatViewModel.allContacts,
      radioID: conversationType.radioID,
      shouldSuppressOpen: { selectedMessageForInfo != nil || emojiPickerMessage != nil }
    )
    // The banner stays above the input bar inside the shared native viewport.
    .chatErrorBanner(chatViewModel: chatViewModel)
    .overlay(alignment: .bottom) {
      ChatConversationMentionOverlay(
        suggestions: mentionSuggestions,
        onSelectMention: { insertMention(for: $0) }
      )
    }
    .chatBottomChrome(canvas: theme.surfaces?.canvas ?? Color(.systemBackground)) {
      ChatConversationInputBar(
        conversationType: conversationType,
        composingText: composingText,
        focusRequest: $inputFocusRequest,
        nodeNameByteCount: appState.connectedDevice?.nodeName.utf8.count ?? 0,
        onSend: { text in
          switch conversationType {
          case .dm:
            await chatViewModel.sendMessage(text: text)
          case .channel:
            await chatViewModel.sendChannelMessage(text: text)
          }
        },
        onWillSend: { scrollToBottomRequest += 1 }
      )
    }
    .navigationHeader(
      title: conversationType.navigationTitle,
      subtitle: conversationType.navigationSubtitle(
        deviceDefaultFloodScopeName: appState.connectedDevice?.defaultFloodScopeName
      ),
      contentScrollsUnderBar: true,
      titleIcon: AnyView(titleAvatar),
      onTitleTap: showInfo
    )
    .toolbar {
      if #unavailable(iOS 26) {
        ToolbarItem(placement: .primaryAction) {
          Button(L10n.Chats.Chats.Common.info, systemImage: "info.circle") {
            showInfo()
          }
        }
      }
    }
    // Info sheet — type-specific
    .sheet(isPresented: $showingInfo, onDismiss: {
      switch conversationType {
      case .dm:
        Task { await refreshContact() }
      case .channel:
        channelInfoTask?.cancel()
        channelInfoTask = Task { _ = try? await refreshChannel() }
      }
    }, content: {
      ChatConversationInfoSheet(
        conversationType: conversationType,
        chatViewModel: chatViewModel,
        onClearChannelMessages: {
          guard case let .channel(channel) = conversationType else { return }
          await chatViewModel.loadChannelMessages(for: channel, populateMode: .replace)
          parentViewModel?.requestConversationReload()
        },
        onClearDirectMessages: {
          guard case let .dm(contact) = conversationType else { return }
          await chatViewModel.loadMessages(for: contact, populateMode: .replace)
          parentViewModel?.requestConversationReload()
        },
        onDeleteChannel: {
          dismiss()
        }
      )
    })
    // "More reactions" emoji picker, opened from the context menu's palette.
    .sheet(item: $emojiPickerMessage) { message in
      EmojiPickerSheet(onSelect: { emoji in dispatch(.react(emoji), for: message) })
    }
    // Message info sheet — the context menu's "Details" action. Bound to a
    // captured value, so messages arriving behind it never re-anchor it to a
    // different bubble.
    .sheet(item: $selectedMessageForInfo) { message in
      MessageInfoSheet(
        message: message,
        senderName: senderResolution(for: message).displayName
      )
      .environment(\.horizontalSizeClass, horizontalSizeClass)
    }
    // Block sender sheet — channel only
    .sheet(item: $blockSenderContext) { context in
      BlockSenderSheet(
        senderName: context.senderName,
        radioID: context.radioID
      ) { blockedContactIDs in
        Task {
          await performBlock(
            senderName: context.senderName,
            radioID: context.radioID,
            contactIDs: blockedContactIDs
          )
        }
      }
    }
    .sheet(item: $sendDMContext) { context in
      SendDMSheet(
        senderName: context.senderName,
        radioID: context.radioID,
        unverifiedNickname: context.unverifiedNickname
      ) { contact in
        appState.navigation.navigateToChat(with: contact)
      }
    }
    .fullScreenCover(item: $imageViewerData) { data in
      FullScreenImageViewer(data: data)
    }
    // A nil task id while the scene is inactive keeps this task from loading or clearing unreads.
    .task(id: scenePhase == .active ? appState.servicesVersion : nil) {
      guard scenePhase == .active else { return }
      await performInitialLoad()
    }
    .task(id: didCompleteInitialLoad ? appState.navigation.pendingScrollTarget?.requestID : nil) {
      await deliverPendingScrollIfNeeded()
    }
    .conversationTranslationSession(
      configuration: $translationConfiguration,
      request: $chatViewModel.translationSessionRequest,
      perform: { translator, request in
        let result = await chatViewModel.performPendingTranslation(using: translator, for: request)
        if case let .presentSystemOverlay(text: text) = result {
          systemTranslationText = text
          showSystemTranslation = true
        }
        return result
      }
    )
    // Overlay after `.conversationTranslationSession`: `.translationPresentation`
    // must not sit in that modifier's `.translationTask` content tree.
    .background {
      Color.clear
        .accessibilityHidden(true)
        .translationPresentation(
          isPresented: $showSystemTranslation,
          text: systemTranslationText
        )
    }
    .onDisappear {
      channelInfoTask?.cancel()
      // Disappearance can beat the debounce, so persist the latest dirty text now.
      draftEditor.flush()
      chatViewModel.cancelPendingTranslation()
      performCleanup()
    }
    .onAppear {
      if slotGenerationOnAppear == nil {
        slotGenerationOnAppear = currentSlotGeneration
      }
    }
    .onChange(of: currentSlotGeneration) { _, _ in
      leaveIfSlotReassigned()
    }
    .onChange(of: scenePhase) { _, newPhase in
      switch newPhase {
      case .active:
        // Becoming active changes the load task id, which reloads and clears delivered notifications.
        break
      case .background, .inactive:
        // The OS can suspend the process before the debounce fires, so flush
        // the draft synchronously here.
        draftEditor.flush()
      @unknown default:
        break
      }
    }
    .onChange(of: activeMentionQuery != nil) { _, isActive in
      if isActive {
        mentionSenderOrder = chatViewModel.channelSenderOrder
      } else {
        mentionSenderOrder = nil
      }
    }
    .task {
      for await event in appState.messageEventStream.events() {
        await chatViewModel.handle(event)
      }
    }
    .onChange(of: chatViewModel.contactRefreshSignal) { _, _ in
      Task { await refreshContact() }
    }
    .onChange(of: chatViewModel.lastIncomingMention) { _, newMention in
      guard let mention = newMention else { return }
      handleIncomingMentionIfNeeded(mention.messageID)
    }
    .onChange(of: appState.contactsVersion) { _, _ in
      // Keep the mention-resolution snapshot fresh: a contact added after the
      // chat opened must be tappable without reopening the screen.
      Task { await chatViewModel.loadAllContacts(radioID: conversationType.radioID) }
    }
    .chatErrorAlerts(chatViewModel: chatViewModel)
    // Inherit themedChrome from the stack to avoid navigation appearance changes reflowing the timeline.
    // Paint the canvas fallback so loading content remains opaque before messages arrive.
    .background {
      (theme.surfaces?.canvas ?? Color(.systemBackground)).ignoresSafeArea()
    }
  }

  // MARK: - Initial Load (.task)

  private func performInitialLoad() async {
    didCompleteInitialLoad = false
    scrollToTargetID = nil

    if case let .dm(contact) = conversationType {
      appState.applyPendingDirectReply(contactID: contact.id, to: draftEditor)
    }

    chatViewModel.configure(
      dependencies: appState.makeChatViewModelDependencies(),
      onNavigateToMap: { appState.navigation.navigateToMap(coordinate: $0) },
      linkPreviewCache: linkPreviewCache,
      chatCoordinatorRegistry: appState.ensureChatCoordinatorRegistry(),
      conversation: conversationType
    )
    chatViewModel.applyEnvInputs(currentEnvInputs)

    switch conversationType {
    case let .dm(contact):
      await chatViewModel.loadMessages(for: contact, populateMode: .refreshWindow)
      guard !Task.isCancelled else { return }
      await chatViewModel.loadConversations(radioID: contact.radioID)
      guard !Task.isCancelled else { return }
      await chatViewModel.loadAllContacts(radioID: contact.radioID)

    case let .channel(channel):
      // Load contacts first so contactNameSet is populated before buildChannelSenders runs
      await chatViewModel.loadAllContacts(radioID: channel.radioID)
      guard !Task.isCancelled else { return }
      await chatViewModel.loadChannelMessages(for: channel, populateMode: .refreshWindow)
      guard !Task.isCancelled else { return }
      await chatViewModel.loadConversations(radioID: channel.radioID)
    }

    guard !Task.isCancelled else { return }
    // Opening the conversation counts as seeing its mentions. Without on-screen
    // bubble tracking, mark them all seen here so chat-list mention badges clear.
    await markConversationMentionsSeen()

    guard !Task.isCancelled else { return }
    didCompleteInitialLoad = true

    // Clear delivered notifications after loading resets the unread count, keeping the badge current.
    await clearDeliveredNotifications()
  }

  private func deliverPendingScrollIfNeeded() async {
    if let targetID = await ChatScrollRequestDelivery.takeIfHonorable(
      from: appState.navigation,
      kind: conversationType.chatRouteKind,
      conversationID: conversationType.conversationID,
      canHonor: didCompleteInitialLoad,
      timeline: chatViewModel.timeline,
      loadOlder: { await chatViewModel.loadOlderMessages() }
    ) {
      scrollToTargetID = targetID
      scrollToTargetRequest += 1
    }
  }

  /// Removes delivered lock-screen / Notification Center notifications for the
  /// conversation the user just opened, then recomputes the app badge.
  private func clearDeliveredNotifications() async {
    guard scenePhase == .active, !Task.isCancelled, let notificationService = appState.services?.notificationService else { return }
    switch conversationType {
    case let .dm(contact):
      await notificationService.removeDeliveredNotifications(forContactID: contact.id)
    case let .channel(channel):
      await notificationService.removeDeliveredNotifications(
        forChannelIndex: channel.index,
        radioID: channel.radioID
      )
    }
    await notificationService.updateBadgeCount()
  }

  // MARK: - Slot Reassignment

  private var currentSlotGeneration: Int? {
    guard case .channel = conversationType else { return nil }
    return appState.channelSlotGenerations[conversationType.coordinatorID] ?? 0
  }

  private var slotWasReassigned: Bool {
    guard let seen = slotGenerationOnAppear, let current = currentSlotGeneration else { return false }
    return current > seen
  }

  /// Closes the chat when another channel took over its slot. The occupant change
  /// already retired this editor, so this view's later flush cannot restore the old text.
  private func leaveIfSlotReassigned() {
    guard slotWasReassigned, case let .channel(channel) = conversationType else { return }
    if case let .channel(selected) = appState.navigation.chatsSelectedRoute, selected.id == channel.id {
      appState.navigation.setChatsRoute(nil)
    }
    dismiss()
  }

  // MARK: - Cleanup (.onDisappear)

  private func performCleanup() {
    // Clear suppression only while this conversation owns it; another open may have claimed it during teardown.
    let service = appState.services?.notificationService
    switch conversationType {
    case let .dm(contact):
      if service?.activeContactID == contact.id {
        service?.activeContactID = nil
      }
    case let .channel(channel):
      if service?.activeChannelIndex == channel.index,
         service?.activeChannelRadioID == channel.radioID {
        service?.activeChannelIndex = nil
        service?.activeChannelRadioID = nil
      }
    }

    // Refresh parent conversation list when leaving
    parentViewModel?.requestConversationReload()

    // Vacate the coordinator's writer slot so arrival-time prime refreshes can
    // service this closed conversation; the load task rebinds on reappearance.
    chatViewModel.releaseTimelineWriter()
  }

  private func handleIncomingMentionIfNeeded(_ messageID: UUID) {
    guard scenePhase == .active else { return }
    // ChatViewModel.recordIncomingMentionIfNeeded gates self-mentions; an open conversation counts them as seen.
    Task { await markNewArrivalMentionSeen(messageID: messageID) }
  }

  // MARK: - Conversation Refresh

  private func refreshContact() async {
    guard case let .dm(contact) = conversationType else { return }
    if let updated = try? await appState.services?.dataStore.fetchContact(id: contact.id) {
      conversationType = conversationType.replacingContact(updated)
      chatViewModel.currentContact = updated
      chatViewModel.timeline.conversation = .dm(updated)
    }
  }

  private func showInfo() {
    channelInfoTask?.cancel()
    switch conversationType {
    case .dm:
      showingInfo = true
    case .channel:
      channelInfoTask = Task {
        do {
          try await refreshChannel()
          showingInfo = true
        } catch {
          guard !Task.isCancelled else { return }
          chatViewModel.errorMessage = error.userFacingMessage
        }
      }
    }
  }

  private func refreshChannel() async throws {
    guard case let .channel(channel) = conversationType else { return }
    guard let dataStore = appState.offlineDataStore else { throw ConnectionError.notConnected }
    guard let updated = try await dataStore.fetchChannel(id: channel.id) else {
      throw PersistenceStoreError.channelNotFound
    }
    try Task.checkCancellation()
    conversationType = conversationType.replacingChannel(updated)
    chatViewModel.currentChannel = updated
    chatViewModel.timeline.conversation = .channel(updated)
  }

  // MARK: - Mention Tracking

  /// Mark unseen mentions as seen on open because chat-list badges track conversation reads, not visible bubbles.
  private func markConversationMentionsSeen() async {
    guard scenePhase == .active, !Task.isCancelled, let dataStore = appState.services?.dataStore else { return }
    do {
      switch conversationType {
      case let .dm(contact):
        let ids = try await dataStore.fetchUnseenMentionIDs(contactID: contact.id)
        for id in ids {
          guard scenePhase == .active, !Task.isCancelled else { return }
          try await dataStore.markMentionSeen(messageID: id)
        }
        guard scenePhase == .active, !Task.isCancelled else { return }
        try await dataStore.clearUnreadMentionCount(contactID: contact.id)

      case let .channel(channel):
        let ids = try await dataStore.fetchUnseenChannelMentionIDs(
          radioID: channel.radioID,
          channelIndex: channel.index
        )
        for id in ids {
          guard scenePhase == .active, !Task.isCancelled else { return }
          try await dataStore.markMentionSeen(messageID: id)
        }
        guard scenePhase == .active, !Task.isCancelled else { return }
        try await dataStore.clearChannelUnreadMentionCount(channelID: channel.id)
      }
      parentViewModel?.requestConversationReload()
    } catch {
      logger.error("Failed to mark conversation mentions seen: \(error)")
    }
  }

  private func markNewArrivalMentionSeen(messageID: UUID) async {
    _ = await persistMentionSeen(messageID: messageID)
  }

  private func persistMentionSeen(messageID: UUID) async -> Bool {
    guard scenePhase == .active, !Task.isCancelled, let dataStore = appState.services?.dataStore else { return false }
    do {
      try await dataStore.markMentionSeen(messageID: messageID)
      guard scenePhase == .active, !Task.isCancelled else { return false }
      switch conversationType {
      case let .dm(contact):
        try await dataStore.decrementUnreadMentionCount(contactID: contact.id)
        parentViewModel?.requestConversationReload()
      case let .channel(channel):
        try await dataStore.decrementChannelUnreadMentionCount(channelID: channel.id)
        parentViewModel?.requestConversationReload()
      }
      return true
    } catch {
      logger.error("Failed to mark mention seen: \(error)")
      return false
    }
  }

  // MARK: - Mention Suggestions

  private var activeMentionQuery: String? {
    MentionUtilities.detectActiveMention(in: draftEditor.text)
  }

  private var mentionSuggestions: [ContactDTO] {
    guard let query = activeMentionQuery else { return [] }
    switch conversationType {
    case .dm:
      return MentionUtilities.filterContacts(chatViewModel.allContacts, query: query)
    case .channel:
      let combined = chatViewModel.allContacts + chatViewModel.channelSenders
      let order = mentionSenderOrder ?? chatViewModel.channelSenderOrder
      return MentionUtilities.filterContacts(combined, query: query, senderOrder: order)
    }
  }

  private func insertMention(for contact: ContactDTO) {
    guard let query = MentionUtilities.detectActiveMention(in: draftEditor.text) else { return }

    let searchPattern = "@" + query
    if let range = draftEditor.text.range(of: searchPattern, options: .backwards) {
      let mention = MentionUtilities.createMention(for: contact.name)
      var updated = draftEditor.text
      updated.replaceSubrange(range, with: mention + " ")
      draftEditor.setText(updated)
    }
  }

  // MARK: - Message Context Menu

  /// Native haptic-touch/right-click context menu shown on long-press of a bubble.
  @ViewBuilder
  private func messageContextMenu(for message: MessageDTO) -> some View {
    let availability = MessageActionAvailability(message: message)

    reactionPalette(for: message)

    if availability.canReply {
      Button {
        dispatch(.reply, for: message)
      } label: {
        Label(
          replyWithQuote
            ? L10n.Chats.Chats.Message.Action.reply
            : L10n.Chats.Chats.Message.Action.mention,
          systemImage: "arrowshape.turn.up.left"
        )
      }
    }
    if availability.canSendDM {
      Button {
        dispatch(.sendDM, for: message)
      } label: {
        Label(L10n.Chats.Chats.Message.Action.sendDM, systemImage: "bubble.left.and.bubble.right")
      }
    }
    Button {
      dispatch(.copy, for: message)
    } label: {
      Label(L10n.Chats.Chats.Message.Action.copy, systemImage: "doc.on.doc")
    }
    Button {
      dispatch(.translate, for: message)
    } label: {
      Label(L10n.Chats.Chats.Message.Action.translate, systemImage: "translate")
    }
    if availability.canSendAgain {
      Button {
        dispatch(.sendAgain, for: message)
      } label: {
        Label(L10n.Chats.Chats.Message.Action.sendAgain, systemImage: "arrow.uturn.forward")
      }
    }

    Button {
      dispatch(.details, for: message)
    } label: {
      Label(L10n.Chats.Chats.Message.Action.details, systemImage: "info.circle")
    }

    Section {
      if availability.canBlockSender {
        Button(role: .destructive) {
          dispatch(.blockSender, for: message)
        } label: {
          Label(L10n.Chats.Chats.Message.Action.blockSender, systemImage: "hand.raised")
        }
      }
      if availability.canDelete {
        Button(role: .destructive) {
          dispatch(.delete, for: message)
        } label: {
          Label(L10n.Chats.Chats.Message.Action.delete, systemImage: "trash")
        }
      }
    }
  }

  /// Quick reactions + "More" rendered as a single horizontal palette row.
  ///
  /// `.compactMenu` produces the horizontal strip only on iOS/iPadOS; the
  /// AppKit `NSMenu` that hosts the menu when this iPad app runs on a Mac
  /// ignores it and stacks each button vertically. `.palette` is the style
  /// that bridges to the AppKit palette presentation, so the Mac path uses it.
  @ViewBuilder
  private func reactionPalette(for message: MessageDTO) -> some View {
    let isOnMac = ProcessInfo.processInfo.isiOSAppOnMac
    let group = ControlGroup {
      ForEach(Array(recentEmojisStore.recentEmojis.prefix(quickReactionCount)), id: \.self) { emoji in
        Button {
          dispatch(.react(emoji), for: message)
        } label: {
          // Mac renders each emoji to an image; iOS/iPadOS draws the Text.
          if isOnMac {
            emojiPaletteImage(emoji)
          } else {
            Text(emoji)
          }
        }
        .accessibilityLabel(emoji.emojiAccessibilityName)
      }
      Button {
        dispatch(.moreEmojis, for: message)
      } label: {
        // "More" goes through the same image path as the emoji so the
        // palette sizes and centers it identically; iOS keeps the Label.
        if isOnMac {
          moreEmojiPaletteImage()
            .accessibilityLabel(L10n.Chats.Reactions.moreEmojis)
        } else {
          Label(L10n.Chats.Reactions.moreEmojis, systemImage: moreEmojiSymbol)
            .environment(\.symbolVariants, .none)
        }
      }
    }

    if isOnMac {
      group.controlGroupStyle(.palette)
    } else {
      group.controlGroupStyle(.compactMenu)
    }
  }

  /// Draws an emoji glyph centered in a fixed square canvas for AppKit palette
  /// menu cells, which draw an item's image rather than its text title.
  private func emojiPaletteImage(_ emoji: String) -> Image {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: emojiPaletteGlyphSize),
    ]
    let glyph = (emoji as NSString).size(withAttributes: attributes)
    let uiImage = paletteCellImage { rect in
      (emoji as NSString).draw(
        at: CGPoint(x: rect.midX - glyph.width / 2, y: rect.midY - glyph.height / 2),
        withAttributes: attributes
      )
    }
    return Image(uiImage: uiImage).renderingMode(.original)
  }

  /// The "More" symbol rendered through the shared palette canvas. Its color is
  /// baked in because the palette does not tint a pre-rendered bitmap the way it
  /// tints the `Label` icons; `chromeTint` is nil on the default theme, where the
  /// icons take the label color like the menu text.
  private func moreEmojiPaletteImage() -> Image {
    let config = UIImage.SymbolConfiguration(pointSize: morePaletteSymbolSize)
    let tintColor = UIColor(theme.chromeTint ?? .primary)
    let symbol = UIImage(systemName: moreEmojiSymbol, withConfiguration: config)?
      .withTintColor(tintColor, renderingMode: .alwaysOriginal)
    let uiImage = paletteCellImage { rect in
      guard let symbol else { return }
      symbol.draw(in: CGRect(
        x: rect.midX - symbol.size.width / 2,
        y: rect.midY - symbol.size.height / 2,
        width: symbol.size.width,
        height: symbol.size.height
      ))
    }
    return Image(uiImage: uiImage).renderingMode(.original)
  }

  /// Renders `draw` into a fixed square canvas shared by every palette reaction
  /// cell, so all cells have identical metrics and center their glyphs alike.
  private func paletteCellImage(_ draw: (CGRect) -> Void) -> UIImage {
    let size = CGSize(width: reactionPaletteCellSize, height: reactionPaletteCellSize)
    return UIGraphicsImageRenderer(size: size).image { _ in
      draw(CGRect(origin: .zero, size: size))
    }
  }

  private func senderResolution(for message: MessageDTO) -> NodeNameResolution {
    if message.isOutgoing {
      return NodeNameResolution(displayName: appState.localNodeName, matchKind: .exact)
    }
    switch conversationType {
    case let .dm(contact):
      return NodeNameResolution(displayName: contact.displayName, matchKind: .exact)
    case .channel:
      return MessageBubbleConfiguration.resolveSenderName(
        for: message,
        contacts: chatViewModel.allContacts,
        nicknamesByLoweredName: chatViewModel.nicknamesByLoweredName
      )
    }
  }

  // MARK: - Message Action Handling

  private func dispatch(_ action: MessageAction, for message: MessageDTO) {
    switch action {
    case let .react(emoji):
      handleReact(emoji: emoji, for: message)
    case .moreEmojis:
      handleMoreEmojis(for: message)
    case .reply:
      handleReply(for: message)
    case .copy:
      handleCopy(for: message)
    case .translate:
      presentSystemTranslation(text: message.text)
    case .sendAgain:
      handleSendAgain(for: message)
    case .details:
      handleDetails(for: message)
    case .blockSender:
      handleBlockSender(for: message)
    case .sendDM:
      handleSendDM(for: message)
    case .delete:
      handleDelete(for: message)
    }
  }

  private func handleReact(emoji: String, for message: MessageDTO) {
    recentEmojisStore.recordUsage(emoji)
    Task { await chatViewModel.sendReaction(emoji: emoji, to: message) }
  }

  private func handleMoreEmojis(for message: MessageDTO) {
    ChatKeyboardLift.resignFirstResponder()
    emojiPickerMessage = message
  }

  private func handleDetails(for message: MessageDTO) {
    ChatKeyboardLift.resignFirstResponder()
    selectedMessageForInfo = message
  }

  private func handleReply(for message: MessageDTO) {
    let mentionName: String = switch conversationType {
    case let .dm(contact):
      contact.name
    case .channel:
      message.senderNodeName ?? L10n.Chats.Chats.Message.Sender.unknown
    }
    if replyWithQuote {
      draftEditor.setText(MentionUtilities.buildReplyText(mentionName: mentionName, messageText: message.text))
    } else {
      draftEditor.setText(MentionUtilities.appendMention(
        for: mentionName,
        to: draftEditor.text
      ))
    }
    // Raise the keyboard only after the actions sheet has finished dismissing;
    // a focus request issued while the sheet is still animating away is lost.
    Task {
      try? await Task.sleep(for: MessageActionsPresentation.dismissalDelay)
      inputFocusRequest += 1
    }
  }

  private func handleCopy(for message: MessageDTO) {
    UIPasteboard.general.string = chatViewModel.displayedText(for: message)
  }

  private func presentSystemTranslation(text: String) {
    systemTranslationText = text
    Task {
      try? await Task.sleep(for: MessageActionsPresentation.dismissalDelay)
      showSystemTranslation = true
    }
  }

  private func handleInBubbleTranslation(for messageID: UUID) {
    if let chrome = chatViewModel.translation(for: messageID),
       case .showing = chrome.phase {
      chatViewModel.performTranslationAction(for: messageID)
      return
    }
    if TranslationTargetPreference.usesSystemOverlay(
      languageRawValue: translationTargetLanguage,
      useDefaultTranslationApp: useDefaultTranslationApp
    ) {
      guard let text = chatViewModel.messagesByID[messageID]?.text else { return }
      systemTranslationText = text
      showSystemTranslation = true
      return
    }
    chatViewModel.performTranslationAction(for: messageID)
  }

  private func handleSendAgain(for message: MessageDTO) {
    Task { await chatViewModel.sendAgain(message) }
  }

  private func handleBlockSender(for message: MessageDTO) {
    guard case let .channel(channel) = conversationType,
          let name = message.senderNodeName else { return }
    Task {
      try? await Task.sleep(for: MessageActionsPresentation.dismissalDelay)
      blockSenderContext = BlockSenderContext(senderName: name, radioID: channel.radioID)
    }
  }

  private func handleSendDM(for message: MessageDTO) {
    guard case let .channel(channel) = conversationType,
          let name = message.senderNodeName else { return }
    let nickname = chatViewModel.nicknamesByLoweredName[name.lowercased()]
    Task {
      try? await Task.sleep(for: MessageActionsPresentation.dismissalDelay)
      sendDMContext = SendDMContext(senderName: name, radioID: channel.radioID, unverifiedNickname: nickname)
    }
  }

  private func handleDelete(for message: MessageDTO) {
    Task { await chatViewModel.deleteMessage(message) }
  }

  private func retryMessage(_ message: MessageDTO) {
    Task {
      switch conversationType {
      case .dm:
        await chatViewModel.retryMessage(message)
      case .channel:
        await chatViewModel.retryChannelMessage(message)
      }
    }
  }

  // MARK: - Blocking (Channel only)

  private func performBlock(senderName: String, radioID: UUID, contactIDs: Set<UUID>) async {
    guard let services = appState.services else { return }

    let dto = BlockedChannelSenderDTO(name: senderName, radioID: radioID)
    do {
      try await services.dataStore.saveBlockedChannelSender(dto)
    } catch {
      logger.error("Failed to save blocked channel sender: \(error)")
      return
    }

    // Delete existing channel messages from the blocked sender
    try? await services.dataStore.deleteChannelMessages(fromSender: senderName, radioID: radioID)

    for contactID in contactIDs {
      do {
        try await services.contactService.updateContactPreferences(
          contactID: contactID,
          isBlocked: true
        )
      } catch {
        logger.error("Failed to block contact \(contactID): \(error)")
      }
    }

    await services.syncCoordinator.refreshBlockedContactsCache(
      radioID: radioID,
      dataStore: services.dataStore
    )

    if !contactIDs.isEmpty {
      services.syncCoordinator.notifyContactsChanged()
    }

    if case let .channel(channel) = conversationType {
      await chatViewModel.loadChannelMessages(for: channel, populateMode: .replace)
    }
    services.syncCoordinator.notifyConversationsChanged()
  }
}

// MARK: - Error Alerts

private extension View {
  /// Group modal chat errors to keep the view body within the type-checker expression budget.
  /// Pagination failures use chatErrorBanner so they remain passive.
  func chatErrorAlerts(chatViewModel: ChatViewModel) -> some View {
    @Bindable var vm = chatViewModel
    return errorAlert($vm.errorMessage)
      .errorAlert($vm.sendErrorMessage, title: L10n.Chats.Chats.Alert.UnableToSend.title)
  }

  /// Keep background failure banners above the input bar in the shared native viewport.
  func chatErrorBanner(chatViewModel: ChatViewModel) -> some View {
    @Bindable var vm = chatViewModel
    return errorBanner($vm.errorBannerMessage)
  }
}

// MARK: - Previews

#Preview("DM") {
  let appState = AppState()
  let contact = ContactDTO(from: Contact(
    radioID: UUID(),
    publicKey: Data(repeating: 0x42, count: 32),
    name: "Alice",
    lastHeardTimestamp: 0
  ))
  NavigationStack {
    ChatConversationView(
      conversationType: .dm(contact),
      draftEditor: appState.chatDraftEditor(for: .dm(radioID: contact.radioID, contactID: contact.id))
    )
  }
  .environment(\.appState, appState)
}

#Preview("Channel") {
  let appState = AppState()
  let channel = ChannelDTO(from: Channel(
    radioID: UUID(),
    index: 1,
    name: "General"
  ))
  NavigationStack {
    ChatConversationView(
      conversationType: .channel(channel),
      draftEditor: appState.chatDraftEditor(
        for: .channel(radioID: channel.radioID, channelIndex: channel.index)
      )
    )
  }
  .environment(\.appState, appState)
}
