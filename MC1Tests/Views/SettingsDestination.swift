@testable import MC1
import Testing

enum SettingsDestination: CaseIterable, Sendable, CustomTestStringConvertible {
  case translateInto
  case manageRegions

  var root: SettingsRoot {
    switch self {
    case .translateInto: .language
    case .manageRegions: .advanced
    }
  }

  var preservesSearch: Bool {
    self == .translateInto
  }

  var row: String {
    switch self {
    case .translateInto: L10n.Settings.Language.TranslateInto.header
    case .manageRegions: L10n.Chats.Chats.ChannelInfo.Region.manageRegions
    }
  }

  var title: String {
    switch self {
    case .translateInto: L10n.Settings.Language.TranslateInto.header
    case .manageRegions: L10n.Chats.Chats.ChannelInfo.Region.manage
    }
  }

  var markers: [String] {
    switch self {
    case .translateInto: [L10n.Settings.Language.matchAppLanguage]
    case .manageRegions: [L10n.Chats.Chats.ChannelInfo.Region.addManually]
    }
  }

  var testDescription: String {
    switch self {
    case .translateInto: "translateInto"
    case .manageRegions: "manageRegions"
    }
  }
}
