/// User actions dispatched from the message context menu, routed to handlers
/// by `ChatConversationView.dispatch(_:for:)`.
enum MessageAction: Equatable {
  case react(String)
  case moreEmojis
  case reply
  case copy
  case sendAgain
  case sendDM
  case details
  case blockSender
  case delete
}
