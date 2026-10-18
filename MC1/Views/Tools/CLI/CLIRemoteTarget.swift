import MC1Services

/// Which node's CLI a remote completion list is for.
enum CLIRemoteTarget: Hashable, Sendable {
  case repeater
  case room

  init(role: RemoteNodeRole) {
    switch role {
    case .repeater: self = .repeater
    case .roomServer: self = .room
    }
  }

  init?(contactType: ContactType) {
    switch contactType {
    case .repeater: self = .repeater
    case .room: self = .room
    case .chat: return nil
    }
  }
}
