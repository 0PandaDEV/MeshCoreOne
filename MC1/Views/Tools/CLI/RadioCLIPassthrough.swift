import Foundation

/// Decides whether a local Tools CLI line should go to `CMD_RUN_CLI_COMMAND`
/// instead of opcode-mapped verbs or custom vars.
enum RadioCLIPassthrough {
  static let getSetKeys: Set<String> = [
    "cad", "int.thresh", "agc.reset.interval",
    "txdelay", "direct.txdelay",
    "tz.offset", "pin",
    "af", "dutycycle", "radio.rxgain", "rxdelay",
    "wifi.ssid", "wifi.clear", "wifi.enabled", "wifi.status", "wifi.ip",
    "radio.fem.rxgain", "radio.fem.txgain",
  ]
  static let setOnlyKeys: Set<String> = ["wifi.pwd"]

  /// Local first words that stay off CMD 66. `poweroff`/`shutdown` have no host
  /// opcode and firmware does not reply, so they must not use the passthrough waiter.
  private static let mappedFirstWords: Set<String> = [
    "clock", "ver", "board", "advert", "advert.zerohop", "floodadv", "reboot",
    "poweroff", "shutdown",
    "get", "set", "help", "clear", "session", "login", "logout", "nodes", "channels",
  ]

  static func shouldSend(_ line: String) -> Bool {
    let parts = line.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    guard let first = parts.first else { return false }

    if first == "get" {
      guard parts.count >= 2 else { return false }
      let key = parts[1]
      if key.hasPrefix("_") { return false }
      return getSetKeys.contains(key)
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
