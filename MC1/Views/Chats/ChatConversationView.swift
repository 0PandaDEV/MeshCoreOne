import MC1Services
import OSLog
import SwiftUI
import UIKit // UIPasteboard for .copy action

private let logger = Logger(subsystem: "com.mc1", category: "ChatConversationView")

/// Quiet period after the last keystroke before the composer draft is persisted,
/// so rapid typing coalesces into a single write.
private let draftSaveDebounce: Duration = .milliseconds(500)

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
  let parentViewModel: ChatViewModel?

  @State private var chatViewModel: ChatViewModel

  // MARK: - Scroll State

  @State private var isAtBottom = true
  @State private var unreadCount = 0
  @State private var scrollToBottomRequest = 0
  /// Bumped to jump the list to `scrollToTargetID` (deeplink target or the
  /// new-messages divider). The library scrolls by item id; no on-screen bubble
  /// tracking is involved.
  @State private var scrollToTargetRequest = 0
  @State private var scrollToTargetID: UUID?

  /// Pending debounced draft persist; cancelled and restarted on each keystroke,
  /// cancelled-then-flushed synchronously on view teardown and app suspension.
  @State private var draftSaveTask: Task<Void, Never>?

  // MARK: - Sheet State

  @State private var showingInfo = false
  @State private var selectedMessageForInfo: MessageDTO?
  @State private var emojiPickerMessage: MessageDTO?
  @State private var blockSenderContext: BlockSenderContext?
  @State private var sendDMContext: SendDMContext?
  @State private var imageViewerData: ImageViewerData?

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
  @AppStorage(AppStorageKey.showIncomingSendTime.rawValue) private var showIncomingSendTime = AppStorageKey.defaultShowIncomingSendTime
  @AppStorage(AppStorageKey.linkPreviewsEnabled.rawValue) private var previewsEnabled = AppStorageKey.defaultLinkPreviewsEnabled
  @AppStorage(AppStorageKey.replyWithQuote.rawValue) private var replyWithQuote = AppStorageKey.defaultReplyWithQuote
  @AppStorage(AppStorageKey.showMapPreviewThumbnails.rawValue) private var showMapPreviewThumbnails = AppStorageKey.defaultShowMapPreviewThumbnails

  // MARK: - Environment

  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.appTheme) private var theme

  /// Snapshot of env-derived inputs the view model needs to construct
  /// MessageItems at write time. Recomputed on every render — Equatable
  /// drives `.onChange(of: envInputs)` in ChatConversationMessagesContent.
  /// Constructed from the observed `@AppStorage` toggles and `@Environment`
  /// values so a settings change while the chat is open re-renders the view and
  /// drives `ChatConversationMessagesContent.onChange(of: envInputs)`. The
  /// navigation-time prefetch reads the same toggles once via `AppState.chatEnvInputs(...)`.
  private var currentEnvInputs: EnvInputs {
    EnvInputs(
      autoPlayGIFs: autoPlayGIFs,
      showIncomingPath: showIncomingPath,
      showIncomingHopCount: showIncomingHopCount,
      showIncomingRegion: showIncomingRegion,
      showIncomingSendTime: showIncomingSendTime,
      previewsEnabled: previewsEnabled,
      isHighContrast: colorSchemeContrast == .increased,
      isDark: colorScheme == .dark,
      showMapPreviews: showMapPreviewThumbnails && !conversationType.suppressesMapPreviews,
      isOffline: !appState.networkMonitor.isNetworkAvailable,
      currentUserName: appState.localNodeName,
      themeID: theme.id,
      contentSizeCategory: AppearanceToken.contentSizeCategoryToken(dynamicTypeSize)
    )
  }

  // MARK: - Init

  init(
    conversationType: ChatConversationType,
    parentViewModel: ChatViewModel? = nil,
    coordinatorRegistry: ChatCoordinatorRegistry? = nil
  ) {
    _conversationType = State(initialValue: conversationType)
    self.parentViewModel = parentViewModel

    // Seed the view model with the shared coordinator up front so a warm
    // (prefetched or previously opened) conversation renders its messages on the
    // first frame, with no empty flash before the load task binds it. Only the
    // reference is attached here; the load task's `configure` installs the
    // rebuild hooks on this persistent instance.
    let viewModel = ChatViewModel()
    if let coordinatorRegistry {
      viewModel.attachCoordinator(coordinatorRegistry.coordinator(for: conversationType.coordinatorID))
    }
    // Stage before the first body evaluation: the anchor decision keys on
    // this open's unread count, and a warm coordinator's items are already
    // on screen in that first frame.
    viewModel.timeline.stageOpen(conversationType)
    _chatViewModel = State(initialValue: viewModel)
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
      makeActionsMenu: { AnyView(messageContextMenu(for: $0)) }
    )
    .mentionTapHandling(
      contacts: chatViewModel.allContacts,
      radioID: conversationType.radioID,
      shouldSuppressOpen: { selectedMessageForInfo != nil || emojiPickerMessage != nil }
    )
    // Banner is applied innermost so its safe-area inset stacks above the
    // input bar inset that follows, placing the strip between content and
    // the input bar (and lifting it with the keyboard).
    .chatErrorBanner(chatViewModel: chatViewModel)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      ChatConversationInputBar(
        conversationType: conversationType,
        composingText: $chatViewModel.composingText,
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
        onWillSend: { scrollToBottomRequest += 1 },
        onFocus: { scrollToBottomRequest += 1 }
      )
      .chatKeyboardLiftPadding()
      .chatComposeBarFade(canvas: theme.surfaces?.canvas ?? Color(.systemBackground))
    }
    // Overlay before `chatKeyboardOwnedLift`: environment does not reach overlays
    // applied after the modifier that publishes `chatKeyboardLift`.
    .overlay(alignment: .bottom) {
      ChatConversationMentionOverlay(
        suggestions: mentionSuggestions,
        onSelectMention: { insertMention(for: $0) }
      )
    }
    // Owned lift: residual system keyboard safe area can park the compose bar
    // mid-screen after an interrupted hide (app switch, notification activation).
    .chatKeyboardOwnedLift()
    .navigationHeader(
      title: conversationType.navigationTitle,
      subtitle: conversationType.navigationSubtitle(
        deviceDefaultFloodScopeName: appState.connectedDevice?.defaultFloodScopeName
      ),
      contentScrollsUnderBar: true,
      titleIcon: AnyView(titleAvatar),
      onTitleTap: { showingInfo = true }
    )
    .toolbar {
      if #unavailable(iOS 26) {
        ToolbarItem(placement: .primaryAction) {
          Button(L10n.Chats.Chats.Common.info, systemImage: "info.circle") {
            showingInfo = true
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
        Task { await refreshChannel() }
      }
    }, content: {
      ChatConversationInfoSheet(
        conversationType: conversationType,
        chatViewModel: chatViewModel,
        onClearChannelMessages: {
          guard case let .channel(channel) = conversationType else { return }
          await chatViewModel.loadChannelMessages(for: channel)
          parentViewModel?.requestConversationReload()
        },
        onClearDirectMessages: {
          guard case let .dm(contact) = conversationType else { return }
          await chatViewModel.loadMessages(for: contact)
          parentViewModel?.requestConversationReload()
        },
        onDeleteChannel: {
          // Clear the composer so the teardown flush doesn't re-persist a draft for the
          // freed slot — a channel later reusing that slot would otherwise surface it.
          chatViewModel.composingText = ""
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
    .task(id: appState.servicesVersion) {
      await performInitialLoad()
    }
    .onDisappear {
      // Load-bearing on iPad: MainSidebarView pins the Chats detail stack with
      // `.id(chatsSelectedRoute.conversationID)`, so a detail swap tears down this view's
      // @State (including draftSaveTask) before the debounce fires — flush here.
      flushDraft()
      performCleanup()
    }
    .onChange(of: chatViewModel.composingText) { _, _ in
      scheduleDraftSave()
    }
    .onChange(of: scenePhase) { _, newPhase in
      // Notifications usually arrive while the app is backgrounded with this
      // chat already on screen, so re-clear the tray when we return to the
      // foreground — the open hook alone never re-fires in that case.
      switch newPhase {
      case .active:
        Task { await clearDeliveredNotifications() }
      case .background, .inactive:
        // The OS can suspend the process before the debounce fires, so flush
        // the draft synchronously here.
        flushDraft()
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
    // Chrome theming comes from the stack-level themedChrome on the TabView. Re-declaring it
    // on this pushed destination makes the nav bar appearance re-install after the push, which
    // reflows the message list's top rows.
    // Always paint an opaque surface — the default theme has no `canvas`, so
    // without the `.systemBackground` fallback the empty loading area is
    // transparent and the white window shows through on a cold first open
    // before messages land. Matches the `chatComposeBarFade` canvas fallback.
    .background {
      (theme.surfaces?.canvas ?? Color(.systemBackground)).ignoresSafeArea()
    }
  }

  // MARK: - Initial Load (.task)

  private func performInitialLoad() async {
    // Capture pending scroll target before loading
    let pendingTarget = appState.navigation.pendingScrollToMessageID
    if pendingTarget != nil {
      appState.navigation.clearPendingScrollToMessage()
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
      await chatViewModel.loadMessages(for: contact)
      await chatViewModel.loadConversations(radioID: contact.radioID)
      await chatViewModel.loadAllContacts(radioID: contact.radioID)
      chatViewModel.restoreComposerDraft(from: appState.draftStore, id: conversationType.draftConversationID)

    case let .channel(channel):
      // Load contacts first so contactNameSet is populated before buildChannelSenders runs
      await chatViewModel.loadAllContacts(radioID: channel.radioID)
      await chatViewModel.loadChannelMessages(for: channel)
      await chatViewModel.loadConversations(radioID: channel.radioID)
      chatViewModel.restoreComposerDraft(from: appState.draftStore, id: conversationType.draftConversationID)
    }

    // Opening the conversation counts as seeing its mentions. Without on-screen
    // bubble tracking, mark them all seen here so chat-list mention badges clear.
    await markConversationMentionsSeen()

    // Trigger scroll to target message if pending (notification deeplink)
    if let targetID = pendingTarget {
      scrollToTargetID = targetID
      scrollToTargetRequest += 1
    }

    // Clear any notifications for this conversation still sitting in the tray
    // (delivered while the app was backgrounded). The load above already
    // cleared the unread count, so the recomputed badge stays correct.
    await clearDeliveredNotifications()
  }

  /// Removes delivered lock-screen / Notification Center notifications for the
  /// conversation the user just opened, then recomputes the app badge.
  private func clearDeliveredNotifications() async {
    guard let notificationService = appState.services?.notificationService else { return }
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

  // MARK: - Draft Persistence

  /// Restarts the debounced draft persist. The post-sleep cancellation guard is
  /// required: `Task.cancel()` only sets a flag and `try?` swallows
  /// `Task.sleep`'s `CancellationError`, so without it a synchronous flush that
  /// already saved could be overwritten by the resuming task re-saving stale text.
  private func scheduleDraftSave() {
    draftSaveTask?.cancel()
    let id = conversationType.draftConversationID
    draftSaveTask = Task {
      try? await Task.sleep(for: draftSaveDebounce)
      guard !Task.isCancelled else { return }
      chatViewModel.saveDraft(to: appState.draftStore, id: id)
    }
  }

  /// Cancels any pending debounce and persists the current draft synchronously, reading the
  /// store from the view's non-optional `@Environment(\.appState)` (matching `performCleanup`).
  private func flushDraft() {
    draftSaveTask?.cancel()
    draftSaveTask = nil
    chatViewModel.saveDraft(to: appState.draftStore, id: conversationType.draftConversationID)
  }

  // MARK: - Cleanup (.onDisappear)

  private func performCleanup() {
    // Clear notification suppression only if this conversation still owns the
    // active slot; a newer conversation's open may have already claimed it
    // before this view tears down.
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
    // Self-mention gating happens upstream in
    // `ChatViewModel.recordIncomingMentionIfNeeded`, which only assigns
    // `lastIncomingMention` when `containsSelfMention` is true. The conversation
    // is open, so the mention counts as seen regardless of scroll position.
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

  private func refreshChannel() async {
    guard case let .channel(channel) = conversationType else { return }
    if let updated = try? await appState.offlineDataStore?.fetchChannel(id: channel.id) {
      conversationType = conversationType.replacingChannel(updated)
      chatViewModel.currentChannel = updated
      chatViewModel.timeline.conversation = .channel(updated)
    }
  }

  // MARK: - Mention Tracking

  /// Marks every unseen mention in this conversation seen and clears its unread
  /// mention count. Called on open: without on-screen bubble tracking, opening
  /// the conversation is what marks mentions seen, keeping chat-list badges correct.
  private func markConversationMentionsSeen() async {
    guard let dataStore = appState.services?.dataStore else { return }
    do {
      switch conversationType {
      case let .dm(contact):
        let ids = try await dataStore.fetchUnseenMentionIDs(contactID: contact.id)
        for id in ids {
          try await dataStore.markMentionSeen(messageID: id)
        }
        try await dataStore.clearUnreadMentionCount(contactID: contact.id)

      case let .channel(channel):
        let ids = try await dataStore.fetchUnseenChannelMentionIDs(
          radioID: channel.radioID,
          channelIndex: channel.index
        )
        for id in ids {
          try await dataStore.markMentionSeen(messageID: id)
        }
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
    guard let dataStore = appState.services?.dataStore else { return false }
    do {
      try await dataStore.markMentionSeen(messageID: messageID)
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
    MentionUtilities.detectActiveMention(in: chatViewModel.composingText)
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
    guard let query = MentionUtilities.detectActiveMention(in: chatViewModel.composingText) else { return }

    let searchPattern = "@" + query
    if let range = chatViewModel.composingText.range(of: searchPattern, options: .backwards) {
      let mention = MentionUtilities.createMention(for: contact.name)
      chatViewModel.composingText.replaceSubrange(range, with: mention + " ")
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

  /// Dispatches a MessageAction by routing to the appropriate handler. The
  /// `switch action` body preserves compile-time exhaustiveness — adding a new
  /// MessageAction case forces this method to handle it. Each case calls an
  /// extracted private method that captures the view-local context it needs
  /// (focus state, AppStorage flags, sheet-presentation contexts).
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
    emojiPickerMessage = message
  }

  private func handleDetails(for message: MessageDTO) {
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
      chatViewModel.composingText = MentionUtilities.buildReplyText(mentionName: mentionName, messageText: message.text)
    } else {
      chatViewModel.composingText = MentionUtilities.appendMention(
        for: mentionName,
        to: chatViewModel.composingText
      )
    }
    // Raise the keyboard only after the actions sheet has finished dismissing;
    // a focus request issued while the sheet is still animating away is lost.
    Task {
      try? await Task.sleep(for: MessageActionsPresentation.dismissalDelay)
      inputFocusRequest += 1
    }
  }

  private func handleCopy(for message: MessageDTO) {
    UIPasteboard.general.string = message.text
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
      await chatViewModel.loadChannelMessages(for: channel)
    }
    services.syncCoordinator.notifyConversationsChanged()
  }
}

// MARK: - Error Alerts

private extension View {
  /// Applies the chat modal-alert surfaces in one modifier so the conversation
  /// view body stays within the type-checker's expression budget. Two modal
  /// alerts: generic "Error" for open-conversation load failures (so a
  /// re-open failure cannot be missed), and "Unable to Send" for queue drain
  /// failures. The passive banner for pagination failures is mounted
  /// separately via `chatErrorBanner` so it can sit above the input bar.
  func chatErrorAlerts(chatViewModel: ChatViewModel) -> some View {
    @Bindable var vm = chatViewModel
    return errorAlert($vm.errorMessage)
      .errorAlert($vm.sendErrorMessage, title: L10n.Chats.Chats.Alert.UnableToSend.title)
  }

  /// Mounts the passive error banner used for background failures (e.g.
  /// older-message pagination). Applied before the input-bar safe-area inset
  /// so the banner appears between the message list and the input bar, and
  /// rises with the keyboard alongside the input bar.
  func chatErrorBanner(chatViewModel: ChatViewModel) -> some View {
    @Bindable var vm = chatViewModel
    return errorBanner($vm.errorBannerMessage)
  }
}

// MARK: - Previews

#Preview("DM") {
  NavigationStack {
    ChatConversationView(
      conversationType: .dm(ContactDTO(from: Contact(
        radioID: UUID(),
        publicKey: Data(repeating: 0x42, count: 32),
        name: "Alice",
        lastHeardTimestamp: 0
      )))
    )
  }
  .environment(\.appState, AppState())
}

#Preview("Channel") {
  NavigationStack {
    ChatConversationView(
      conversationType: .channel(ChannelDTO(from: Channel(
        radioID: UUID(),
        index: 1,
        name: "General"
      )))
    )
  }
  .environment(\.appState, AppState())
}
