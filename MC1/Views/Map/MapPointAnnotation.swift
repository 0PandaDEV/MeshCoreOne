import MapKit

/// `MKAnnotation` wrapper for a `MapPoint`, generic across every map screen
/// (contacts, discovered nodes, LOS points, trace-path hops, location-history
/// fixes, SNR badges). Title/subtitle are deliberately left nil — this app
/// draws its own hosted SwiftUI content (`MC1PinAnnotationView`) and shows
/// selection via its own popover, so MapKit never gets a chance to layer its
/// own native callout title on top and duplicate the name.
final class MapPointAnnotation: NSObject, MKAnnotation {
  let point: MapPoint

  var coordinate: CLLocationCoordinate2D { point.coordinate }

  init(point: MapPoint) {
    self.point = point
    super.init()
  }

  override var hash: Int { point.id.hashValue }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? MapPointAnnotation else { return false }
    return point.id == other.point.id
  }
}
