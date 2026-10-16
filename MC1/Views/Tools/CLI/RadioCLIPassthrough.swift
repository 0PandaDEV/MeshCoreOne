import Foundation

/// Decides whether a local Tools CLI line should go to `CMD_RUN_CLI_COMMAND`
/// instead of opcode-mapped verbs or custom vars.
enum RadioCLIPassthrough {
  static let getSetKeys: Set<String> = [
    "af", "dutycycle", "int.thresh", "cad", "radio.rxgain", "rxdelay",
    "agc.reset.interval", "txdelay", "direct.txdelay",
    "tz.offset", "wifi.ssid", "wifi.pwd", "wifi.enabled",
    "radio.fem.rxgain", "radio.fem.txgain", "fan",
  ]
  static let getOnlyKeys: Set<String> = ["wifi.status", "wifi.ip"]
  static let setOnlyKeys: Set<String> = ["pin", "wifi.clear", "fan.lo", "fan.hi"]
  /// The radio powers off without sending `RESP_CODE_CLI_REPLY`, so a reply waiter would time out.
  static let noReplyCommands: Set<String> = ["poweroff", "shutdown"]

  private static let mappedFirstWords: Set<String> = [
    "clock", "ver", "board", "advert", "advert.zerohop", "floodadv", "reboot",
    "get", "set", "help", "clear", "session", "login", "logout", "nodes", "channels",
  ]

  static func shouldSend(_ line: String) -> Bool {
    let parts = line.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    guard let first = parts.first else { return false }
    if noReplyCommands.contains(first) { return false }

    if first == "get" {
      guard parts.count >= 2 else { return false }
      let key = parts[1]
      if key.hasPrefix("_") { return false }
      return getSetKeys.contains(key) || getOnlyKeys.contains(key)
    }
    if first == "set" {
      guard parts.count >= 2 else { return false }
      let key = parts[1]
      if key.hasPrefix("_") { return false }
      return getSetKeys.contains(key) || setOnlyKeys.contains(key)
    }
    if mappedFirstWords.contains(first) { return false }
    return true
  }
}
