import MC1Services
import SwiftUI

struct ContactActionsSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  let currentContact: ContactDTO
  @Binding var isFavorite: Bool
  let showFromDirectChat: Bool
  let isPinging: Bool
  let pingResult: PingResult?
  let onJoinRoom: () -> Void
  let onShowTelemetry: () -> Void
  let onShowRemoteCLI: () -> Void
  let onShowAdminAccess: () -> Void
  let onPingRepeater: () -> Void
  let onShareQR: () -> Void
  let onShareViaAdvert: () -> Void
  let isSharing: Bool
  let showShareSuccess: Bool
  let historyRoute: ((ContactRoute.TelemetryHistory) -> NodesRoute)?
  let onRowPosition: (ContactDetailRowPosition.Measurement) -> Void

  var body: some View {
    switch currentContact.type {
    case .room:
      Section {
        joinRoomButton
        nodeActionRows(onRowPosition: nil)
        shareRows
        favoriteRow(reportsPosition: false)
      }
      .themedRowBackground(theme)
    case .repeater:
      Section {
        nodeActionRows(onRowPosition: onRowPosition)
        shareRows
        favoriteRow(reportsPosition: false)
      }
      .themedRowBackground(theme)
    case .chat:
      chatSections
    }
  }

  private var showsSendMessage: Bool {
    !showFromDirectChat && !currentContact.isBlocked
  }

  private var showsRemoteCLI: Bool {
    currentContact.showsRemoteCLI(localRadioSupportsCLI: appState.connectedDevice?.supportsRadioCLI == true)
  }

  private var isRadioReady: Bool {
    appState.connectionState == .ready
  }

  @ViewBuilder
  private var chatSections: some View {
    Section {
      if showsSendMessage {
        sendMessageButton
          .modifier(ContactDetailRowPosition(section: .actions, onPosition: onRowPosition))
      }
      favoriteRow(reportsPosition: !showsSendMessage)
    }
    .themedRowBackground(theme)

    Section {
      telemetryButton
      savedHistoryLink(showNeighbors: false)
    }
    .themedRowBackground(theme)

    Section {
      shareRows
    }
    .themedRowBackground(theme)

    if showsRemoteCLI {
      Section {
        remoteCLIButton
      } footer: {
        Text(L10n.Contacts.Contacts.Detail.remoteCLIFooter)
      }
      .themedRowBackground(theme)
    }
  }

  private var joinRoomButton: some View {
    Button(action: onJoinRoom) {
      Label(L10n.Contacts.Contacts.Detail.joinRoom, systemImage: "door.left.hand.open")
    }
    .radioDisabled(for: appState.connectionState)
    .modifier(ContactDetailRowPosition(section: .actions, onPosition: onRowPosition))
  }

  private var sendMessageButton: some View {
    Button {
      appState.navigation.navigateToChat(with: currentContact)
    } label: {
      Label(L10n.Contacts.Contacts.Detail.sendMessage, systemImage: "message.fill")
    }
    .radioDisabled(for: appState.connectionState)
  }

  private var telemetryButton: some View {
    Button(action: onShowTelemetry) {
      Label(L10n.Contacts.Contacts.Detail.telemetry, systemImage: "chart.line.uptrend.xyaxis")
    }
    .radioDisabled(for: appState.connectionState)
  }

  private var remoteCLIButton: some View {
    Button(action: onShowRemoteCLI) {
      Label(L10n.Contacts.Contacts.Detail.remoteCLI, systemImage: "terminal")
    }
    .radioDisabled(for: appState.connectionState)
  }

  private func nodeActionRows(
    onRowPosition: ((ContactDetailRowPosition.Measurement) -> Void)?
  ) -> some View {
    NodeActionRows(
      contact: currentContact,
      pingLabel: L10n.Contacts.Contacts.Detail.ping,
      isPinging: isPinging,
      pingResult: pingResult,
      connectionState: appState.connectionState,
      onShowTelemetry: onShowTelemetry,
      onShowAdminAccess: onShowAdminAccess,
      onPing: onPingRepeater,
      historyRoute: historyRoute,
      onRowPosition: onRowPosition
    )
  }

  private func savedHistoryLink(showNeighbors: Bool) -> some View {
    ContactSavedHistoryLink(
      route: ContactRoute.TelemetryHistory(
        publicKey: currentContact.publicKey,
        radioID: currentContact.radioID,
        showNeighbors: showNeighbors
      ),
      nodesRoute: historyRoute
    )
  }

  @ViewBuilder
  private var shareRows: some View {
    Button(action: onShareQR) {
      Label(L10n.Contacts.Contacts.Detail.shareContact, systemImage: "square.and.arrow.up")
    }

    Button(action: onShareViaAdvert) {
      if isSharing || showShareSuccess {
        AsyncActionLabel(isLoading: isSharing, showSuccess: showShareSuccess) {
          EmptyView()
        }
      } else {
        Label(L10n.Contacts.Contacts.Detail.shareViaAdvert, systemImage: "antenna.radiowaves.left.and.right")
      }
    }
    .radioDisabled(for: appState.connectionState, or: isSharing || showShareSuccess)
  }

  private func favoriteRow(reportsPosition: Bool) -> some View {
    Toggle(isOn: $isFavorite) {
      Label(L10n.Contacts.Contacts.Detail.favorite, systemImage: "star")
        .foregroundStyle(isRadioReady ? .primary : .secondary)
    }
    .disabled(!isRadioReady)
    .accessibilityHint(
      L10n.Localizable.Accessibility.requiresRadioConnection,
      isEnabled: !isRadioReady
    )
    .modifier(
      ContactDetailRowPosition(
        section: .actions,
        onPosition: reportsPosition ? onRowPosition : nil
      )
    )
  }
}
