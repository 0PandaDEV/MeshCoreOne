import UserNotifications

extension NotificationService {
  /// Writes the icon badge from local unread counts. Used when no `NotificationService` is connected.
  public static func updateAppIconBadge(unreadCounts: (contacts: Int, channels: Int, rooms: Int)) async {
    let count = badgeCount(unreadCounts: unreadCounts, preferences: NotificationPreferences())
    try? await UNUserNotificationCenter.current().setBadgeCount(count)
  }

  static func badgeCount(
    unreadCounts: (contacts: Int, channels: Int, rooms: Int),
    preferences: NotificationPreferences
  ) -> Int {
    guard preferences.badgeEnabled else { return 0 }
    return (preferences.contactMessagesEnabled ? unreadCounts.contacts : 0)
      + (preferences.channelMessagesEnabled ? unreadCounts.channels : 0)
      + (preferences.roomMessagesEnabled ? unreadCounts.rooms : 0)
  }
}
