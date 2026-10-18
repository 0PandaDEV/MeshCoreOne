import Foundation
import MC1Services
import Observation

/// Radio CLI WiFi settings for a paired 1.18.0 radio.
@Observable
@MainActor
final class RadioWiFiViewModel {
  private static let connectedStatus = "connected"
  private static let enabledValue = "1"
  private static let disabledValue = "0"
  private static let minSSIDBytes = 1
  private static let maxSSIDBytes = 32
  private static let maxPasswordBytes = 63

  private var settingsServiceProvider: @MainActor () -> SettingsService? = { nil }
  private var connectionStateProvider: @MainActor () -> DeviceConnectionState = { .disconnected }
  private var connectedDeviceProvider: @MainActor () -> DeviceDTO? = { nil }
  private var currentTransportTypeProvider: @MainActor () -> TransportType? = { nil }
  private var rebootAction: @MainActor () async throws -> Void = {}

  /// The settings service whose rows are still due. A read starts only while the
  /// editor is closed and this view model is idle, and only that service may replace the rows.
  private var owedSettingsService: SettingsService?

  private(set) var showsSection = false
  private(set) var isLoading = false
  private(set) var isWriting = false
  var errorMessage: String?
  private(set) var statusConnected = false
  private(set) var ipAddress: String?
  private(set) var networkName: String?
  private(set) var wifiEnabled = false
  private(set) var rebootPending = false
  var editorOpen = false {
    didSet {
      guard oldValue, editorOpen == false else { return }
      Task { await startOwedRead() }
    }
  }

  var ssidField = ""
  var passwordField = ""
  var showingWiFiWarning = false
  var showingClearConfirm = false
  var showingRebootConfirm = false

  private var loadedSSID = ""
  private var loadedPassword = ""
  private var pendingWiFiAction: WiFiWarningAction?

  /// The SSID, password, and whether the password differs from the loaded one.
  /// Captured when Save is tapped. Later edits do not change the commands.
  private struct WiFiCredentialSubmission: Equatable {
    var ssid: String
    var password: String
    var passwordChanged: Bool
  }

  private enum WiFiWarningAction {
    case save(WiFiCredentialSubmission)
    case disable
  }

  private var settingsService: SettingsService? {
    settingsServiceProvider()
  }

  private var transportIsWiFi: Bool {
    currentTransportTypeProvider() == .wifi
  }

  var showsConnectOverWiFi: Bool {
    currentTransportTypeProvider() == .bluetooth && statusConnected && ipAddress != nil
  }

  var isBusy: Bool {
    isLoading || isWriting
  }

  var canRunCommands: Bool {
    connectionStateProvider() == .ready && !isBusy
  }

  var canSave: Bool {
    guard canRunCommands else { return false }
    guard ssidField != loadedSSID || passwordField != loadedPassword else { return false }
    let nameBytes = Self.utf8ByteCount(ssidField)
    guard nameBytes >= Self.minSSIDBytes, nameBytes <= Self.maxSSIDBytes else { return false }
    return Self.utf8ByteCount(passwordField) <= Self.maxPasswordBytes
  }

  var canClear: Bool {
    networkName != nil && canRunCommands
  }

  var editorFooter: String {
    let nameBytes = Self.utf8ByteCount(ssidField)
    if nameBytes < Self.minSSIDBytes {
      return L10n.Settings.RadioWiFi.Editor.emptyName
    }
    if nameBytes > Self.maxSSIDBytes {
      return L10n.Settings.RadioWiFi.Editor.nameLength
    }
    if Self.utf8ByteCount(passwordField) > Self.maxPasswordBytes {
      return L10n.Settings.RadioWiFi.Editor.passwordLength
    }
    return L10n.Settings.RadioWiFi.Editor.footer
  }

  var clearMessage: String {
    if transportIsWiFi {
      return L10n.Settings.RadioWiFi.Alert.Clear.wifiMessage
    }
    return L10n.Settings.RadioWiFi.Alert.Clear.message
  }

  var rebootMessage: String {
    if let networkName {
      return L10n.Settings.RadioWiFi.Alert.Reboot.join(networkName)
    }
    return L10n.Settings.RadioWiFi.Alert.Reboot.restart
  }

  var linkWarningTitle: String {
    switch pendingWiFiAction {
    case .save:
      L10n.Settings.RadioWiFi.Alert.Save.title
    case .disable, nil:
      L10n.Settings.RadioWiFi.Alert.TurnOff.title
    }
  }

  var linkWarningConfirmTitle: String {
    switch pendingWiFiAction {
    case .save:
      L10n.Localizable.Common.save
    case .disable, nil:
      L10n.Settings.RadioWiFi.Alert.TurnOff.confirm
    }
  }

  func configure(
    settingsService: @escaping @MainActor () -> SettingsService?,
    connectionState: @escaping @MainActor () -> DeviceConnectionState,
    connectedDevice: @escaping @MainActor () -> DeviceDTO?,
    currentTransportType: @escaping @MainActor () -> TransportType?,
    reboot: @escaping @MainActor () async throws -> Void
  ) {
    settingsServiceProvider = settingsService
    connectionStateProvider = connectionState
    connectedDeviceProvider = connectedDevice
    currentTransportTypeProvider = currentTransportType
    rebootAction = reboot
  }

  /// Clears the live link rows while the phone is down, or owes one snapshot for the current service.
  func noteSessionReadiness() async {
    guard connectionStateProvider() == .ready, let settings = settingsService else {
      statusConnected = false
      ipAddress = nil
      owedSettingsService = nil
      return
    }
    owedSettingsService = settings
    await startOwedRead()
  }

  func load() async {
    guard !isBusy else { return }
    guard connectedDeviceProvider()?.supportsRadioCLI == true else {
      showsSection = false
      return
    }
    guard let settings = settingsService else {
      showsSection = false
      return
    }
    await performSnapshot(from: settings)
    await continueOwedRead()
  }

  func loadEditor() async {
    guard !isBusy else { return }
    ssidField = loadedSSID
    passwordField = loadedPassword
    guard let settings = settingsService else { return }
    isLoading = true
    do {
      let password = try await settings.getRadioCLIValue(RadioCLIKey.wifiPassword)
      if settingsService === settings, Task.isCancelled == false {
        loadedPassword = Self.storedPassword(password)
        passwordField = loadedPassword
        await refreshRebootPending(from: settings)
      }
    } catch is CancellationError {
      // Cancellation leaves the password fields and does not set an error.
    } catch {
      if settingsService === settings {
        errorMessage = error.userFacingMessage
      }
    }
    isLoading = false
    await continueOwedRead()
  }

  func setWiFiEnabled(_ enabled: Bool) async {
    guard canRunCommands else { return }
    if !enabled, transportIsWiFi {
      presentLinkWarning(.disable)
      return
    }
    await writeEnabled(enabled)
  }

  func requestSave() async {
    guard canSave else { return }
    let submission = WiFiCredentialSubmission(
      ssid: ssidField,
      password: passwordField,
      passwordChanged: passwordField != loadedPassword
    )
    if transportIsWiFi {
      presentLinkWarning(.save(submission))
      return
    }
    await performSave(submission)
  }

  func requestClear() {
    guard canRunCommands else { return }
    showingClearConfirm = true
  }

  func continuePastWiFiWarning() async {
    let action = pendingWiFiAction
    pendingWiFiAction = nil
    showingWiFiWarning = false
    switch action {
    case let .save(submission):
      await performSave(submission)
    case .disable:
      await writeEnabled(false)
    case nil:
      break
    }
  }

  func cancelWiFiWarning() {
    pendingWiFiAction = nil
    showingWiFiWarning = false
  }

  private func presentLinkWarning(_ action: WiFiWarningAction) {
    pendingWiFiAction = action
    showingWiFiWarning = true
  }

  func confirmClear() async {
    guard canRunCommands else { return }
    showingClearConfirm = false
    guard let settings = settingsService else {
      errorMessage = SettingsServiceError.notConnected.userFacingMessage
      return
    }
    isWriting = true
    do {
      try await settings.setRadioCLIValue(RadioCLIKey.wifiClear, to: nil)
      if settingsService === settings {
        loadedSSID = ""
        loadedPassword = ""
        ssidField = ""
        passwordField = ""
        networkName = nil
        await refreshRebootPending(from: settings)
      }
    } catch {
      if settingsService === settings {
        errorMessage = error.userFacingMessage
      }
    }
    isWriting = false
    await continueOwedRead()
  }

  func requestReboot() {
    guard canRunCommands else { return }
    showingRebootConfirm = true
  }

  func cancelReboot() {
    showingRebootConfirm = false
  }

  func confirmReboot() async {
    showingRebootConfirm = false
    guard canRunCommands else { return }
    do {
      try await rebootAction()
    } catch {
      switch error {
      case BLEError.notConnected, BLEError.operationTimeout:
        // The radio reboots without a reply and drops the link.
        break
      case WiFiTransportError.notConnected, WiFiTransportError.sendTimeout:
        break
      default:
        errorMessage = error.userFacingMessage
      }
    }
  }

  private func performSave(_ submission: WiFiCredentialSubmission) async {
    guard canRunCommands else { return }
    guard let settings = settingsService else {
      errorMessage = SettingsServiceError.notConnected.userFacingMessage
      return
    }
    isWriting = true
    let ssidChanged = submission.ssid != loadedSSID
    do {
      if ssidChanged || submission.passwordChanged {
        try await settings.setRadioCLIValue(RadioCLIKey.wifiSSID, to: submission.ssid)
        if settingsService === settings {
          loadedSSID = submission.ssid
          networkName = Self.displayedNetworkName(submission.ssid)
        }
      }
      if submission.passwordChanged, settingsService === settings {
        try await settings.setRadioCLIValue(RadioCLIKey.wifiPassword, to: submission.password)
        if settingsService === settings {
          loadedPassword = submission.password
        }
      }
      if settingsService === settings {
        await refreshRebootPending(from: settings)
        editorOpen = false
      }
    } catch {
      if settingsService === settings {
        errorMessage = error.userFacingMessage
        await refreshRebootPending(from: settings)
      }
    }
    isWriting = false
    await continueOwedRead()
  }

  private func writeEnabled(_ enabled: Bool) async {
    guard canRunCommands else { return }
    guard let settings = settingsService else {
      errorMessage = SettingsServiceError.notConnected.userFacingMessage
      return
    }
    isWriting = true
    do {
      try await settings.setRadioCLIValue(
        RadioCLIKey.wifiEnabled,
        to: enabled ? Self.enabledValue : Self.disabledValue
      )
      if settingsService === settings {
        wifiEnabled = enabled
        await refreshRebootPending(from: settings)
      }
    } catch {
      if settingsService === settings {
        errorMessage = error.userFacingMessage
      }
    }
    isWriting = false
    await continueOwedRead()
  }

  private func performSnapshot(from settings: SettingsService) async {
    isLoading = true
    defer { isLoading = false }
    do {
      let enabled = try await settings.getRadioCLIValue(RadioCLIKey.wifiEnabled)
      guard shouldApplySnapshot(from: settings) else { return }
      guard let enabled else {
        showsSection = false
        return
      }
      let ssid = try await settings.getRadioCLIValue(RadioCLIKey.wifiSSID)
      guard shouldApplySnapshot(from: settings) else { return }
      let status = try await settings.getRadioCLIValue(RadioCLIKey.wifiStatus)
      guard shouldApplySnapshot(from: settings) else { return }
      let ip = try await settings.getRadioCLIValue(RadioCLIKey.wifiIP)
      guard shouldApplySnapshot(from: settings) else { return }
      let rebootPending = await settings.radioWiFiRebootPending
      guard shouldApplySnapshot(from: settings) else { return }
      applyLoad(enabled: enabled, ssid: ssid, status: status, ip: ip, rebootPending: rebootPending)
    } catch is CancellationError {
      // Cancellation leaves the previous rows and does not set an error.
    } catch {
      if settingsService === settings {
        errorMessage = error.userFacingMessage
      }
    }
  }

  private func shouldApplySnapshot(from settings: SettingsService) -> Bool {
    guard Task.isCancelled == false else { return false }
    guard settingsService === settings else { return false }
    if let owed = owedSettingsService, owed !== settings {
      return false
    }
    return true
  }

  /// Starts the owed read when the editor is closed, the phone is ready, and no read or write is running.
  /// A cancelled caller starts that read on a new task so it does not drop the service a replacement caller just owed.
  private func continueOwedRead() async {
    if Task.isCancelled {
      Task { await self.startOwedRead(hopIfCancelled: false) }
      return
    }
    await startOwedRead(hopIfCancelled: true)
  }

  private func startOwedRead() async {
    await startOwedRead(hopIfCancelled: true)
  }

  private func startOwedRead(hopIfCancelled: Bool) async {
    if Task.isCancelled {
      if hopIfCancelled {
        Task { await self.startOwedRead(hopIfCancelled: false) }
      }
      return
    }
    guard connectionStateProvider() == .ready else { return }
    guard editorOpen == false, isBusy == false else { return }
    guard let owed = owedSettingsService else { return }
    guard settingsService === owed else {
      owedSettingsService = nil
      return
    }
    guard connectedDeviceProvider()?.supportsRadioCLI == true else {
      owedSettingsService = nil
      showsSection = false
      return
    }
    owedSettingsService = nil
    await performSnapshot(from: owed)
    await continueOwedRead()
  }

  private func applyLoad(
    enabled: String,
    ssid: String?,
    status: String?,
    ip: String?,
    rebootPending: Bool
  ) {
    showsSection = true
    wifiEnabled = enabled.trimmingCharacters(in: .whitespacesAndNewlines) == Self.enabledValue
    loadedSSID = Self.storedSSID(ssid)
    networkName = Self.displayedNetworkName(loadedSSID)
    let statusText = status?.trimmingCharacters(in: .whitespacesAndNewlines)
    statusConnected = statusText == Self.connectedStatus
    ipAddress = Self.displayedIP(ip)
    self.rebootPending = rebootPending
  }

  private func refreshRebootPending(from settings: SettingsService) async {
    let pending = await settings.radioWiFiRebootPending
    guard settingsService === settings else { return }
    rebootPending = pending
  }

  private static func utf8ByteCount(_ value: String) -> Int {
    Data(value.utf8).count
  }

  /// The SSID reply, unchanged. `(not set)` and an empty value mean no network.
  private static func storedSSID(_ value: String?) -> String {
    guard let value, !value.isEmpty, value != RadioCLIReply.notSet else { return "" }
    return value
  }

  /// The password reply, unchanged. The password has no sentinel.
  private static func storedPassword(_ value: String?) -> String {
    value ?? ""
  }

  private static func displayedNetworkName(_ ssid: String) -> String? {
    if ssid.isEmpty || ssid == RadioCLIReply.notSet { return nil }
    return ssid
  }

  /// `(not connected)` and an empty value mean no address. Other text is kept.
  private static func displayedIP(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value != RadioCLIReply.notConnected else { return nil }
    return value
  }
}
