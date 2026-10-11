import MC1Services

extension ChatViewModel {
  func setReadState(_ conversation: Conversation, isRead: Bool) async {
    guard let dataStore else {
      errorMessage = L10n.Chats.Chats.Error.readStateSaveFailed
      return
    }

    do {
      switch conversation {
      case let .direct(contact):
        try await dataStore.setContactReadState(contact.id, isRead: isRead)
      case let .channel(channel):
        try await dataStore.setChannelReadState(channel.id, isRead: isRead)
      case let .room(session):
        try await dataStore.setRoomReadState(session.id, isRead: isRead)
      }
    } catch {
      logger.error("Failed to save conversation read state: \(error)")
      errorMessage = L10n.Chats.Chats.Error.readStateSaveFailed
      return
    }

    await requestConversationReload()?.value
    await refreshReadStateBadge(dataStore: dataStore)
  }

  private func refreshReadStateBadge(dataStore: DataStore) async {
    if let notificationService {
      await notificationService.updateBadgeCount()
      return
    }
    guard let radioID = currentRadioIDProvider() else { return }
    do {
      let counts = try await dataStore.getTotalUnreadCounts(radioID: radioID)
      guard currentRadioIDProvider() == radioID else { return }
      if let notificationService {
        await notificationService.updateBadgeCount()
      } else {
        await NotificationService.updateAppIconBadge(unreadCounts: counts)
      }
    } catch {
      logger.warning("Failed to refresh unread badge: \(error)")
    }
  }
}
