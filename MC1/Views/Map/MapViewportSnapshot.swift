import CoreLocation
import MapKit

/// A retained `MKMapCamera` so a remounted map resumes the viewport its
/// predecessor left, rather than refitting.
struct MapViewportSnapshot: Equatable, Sendable {
  private static let coordinateTolerance = 1e-6
  private static let distanceTolerance = 1.0

  let latitude: Double
  let longitude: Double
  /// Camera altitude over the center coordinate, in meters.
  let distance: Double
  let heading: Double
  let pitch: Double
  let appliedCameraCommandVersion: Int

  @MainActor
  init(mapView: MKMapView, appliedCameraCommandVersion: Int = 0) {
    let camera = mapView.camera
    latitude = camera.centerCoordinate.latitude
    longitude = camera.centerCoordinate.longitude
    distance = camera.centerCoordinateDistance
    heading = camera.heading
    pitch = Double(camera.pitch)
    self.appliedCameraCommandVersion = appliedCameraCommandVersion
  }

  init(
    latitude: Double, longitude: Double, distance: Double, heading: Double, pitch: Double,
    appliedCameraCommandVersion: Int = 0
  ) {
    self.latitude = latitude
    self.longitude = longitude
    self.distance = distance
    self.heading = heading
    self.pitch = pitch
    self.appliedCameraCommandVersion = appliedCameraCommandVersion
  }

  @MainActor
  func apply(to mapView: MKMapView, northLocked: Bool) {
    let camera = MKMapCamera(
      lookingAtCenter: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      fromDistance: distance,
      pitch: CGFloat(pitch),
      heading: northLocked ? 0 : heading
    )
    mapView.setCamera(camera, animated: false)
  }

  /// Whether applying `other` over this viewport would visibly move the map.
  func isApproximatelyEqual(to other: MapViewportSnapshot) -> Bool {
    abs(latitude - other.latitude) < Self.coordinateTolerance
      && abs(longitude - other.longitude) < Self.coordinateTolerance
      && abs(distance - other.distance) < Self.distanceTolerance
  }
}
