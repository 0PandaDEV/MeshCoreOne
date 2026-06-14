import Foundation

enum GPSSource: String, Sendable, CaseIterable {
    case phone
    case device
}

/// Desired horizontal accuracy for phone-GPS auto-updates.
///
/// `.best` requests the most accurate fix the device can provide. The metered
/// cases trade accuracy for battery, accepting a fix within the given radius
/// (in meters) — from 100 m up to 1 km in 100 m steps.
enum LocationAccuracy: Int, Sendable, CaseIterable, Identifiable {
    case best = 0
    case meters100 = 100
    case meters200 = 200
    case meters300 = 300
    case meters400 = 400
    case meters500 = 500
    case meters600 = 600
    case meters700 = 700
    case meters800 = 800
    case meters900 = 900
    case kilometer = 1000

    var id: Int { rawValue }

    /// Radius in meters, or `nil` for best-possible accuracy.
    var radiusMeters: Int? { self == .best ? nil : rawValue }
}

struct DevicePreferenceStore {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Auto-Update Location

    func isAutoUpdateLocationEnabled(deviceID: UUID) -> Bool {
        userDefaults.bool(forKey: Self.autoUpdateLocationKey(deviceID: deviceID))
    }

    func setAutoUpdateLocationEnabled(_ enabled: Bool, deviceID: UUID) {
        userDefaults.set(enabled, forKey: Self.autoUpdateLocationKey(deviceID: deviceID))
    }

    // MARK: - GPS Source

    func gpsSource(deviceID: UUID) -> GPSSource {
        guard let raw = userDefaults.string(forKey: Self.gpsSourceKey(deviceID: deviceID)),
              let source = GPSSource(rawValue: raw) else {
            return .phone
        }
        return source
    }

    func hasSetGPSSource(deviceID: UUID) -> Bool {
        userDefaults.string(forKey: Self.gpsSourceKey(deviceID: deviceID)) != nil
    }

    func setGPSSource(_ source: GPSSource, deviceID: UUID) {
        userDefaults.set(source.rawValue, forKey: Self.gpsSourceKey(deviceID: deviceID))
    }

    // MARK: - Location Accuracy

    func locationAccuracy(deviceID: UUID) -> LocationAccuracy {
        let key = Self.locationAccuracyKey(deviceID: deviceID)
        guard userDefaults.object(forKey: key) != nil,
              let accuracy = LocationAccuracy(rawValue: userDefaults.integer(forKey: key)) else {
            return .best
        }
        return accuracy
    }

    func setLocationAccuracy(_ accuracy: LocationAccuracy, deviceID: UUID) {
        userDefaults.set(accuracy.rawValue, forKey: Self.locationAccuracyKey(deviceID: deviceID))
    }

    // MARK: - Keys

    private static func autoUpdateLocationKey(deviceID: UUID) -> String {
        "device.\(deviceID.uuidString).autoUpdateLocation"
    }

    private static func gpsSourceKey(deviceID: UUID) -> String {
        "device.\(deviceID.uuidString).gpsSource"
    }

    private static func locationAccuracyKey(deviceID: UUID) -> String {
        "device.\(deviceID.uuidString).locationAccuracy"
    }
}
