import MapKit

/// Map style options for the Map tab. Apple Maps has no distinct topographic
/// style, so this only offers the two native basemaps.
enum MapStyleSelection: String, CaseIterable, Hashable {
  case standard
  case satellite

  var label: String {
    switch self {
    case .standard: L10n.Map.Map.Style.standard
    case .satellite: L10n.Map.Map.Style.satellite
    }
  }

  /// Native Apple Maps type. Satellite is plain imagery (no roads/labels),
  /// matching how "Satellite" reads in Apple's own Maps app (as distinct from
  /// "Hybrid").
  var mapType: MKMapType {
    switch self {
    case .standard: .standard
    case .satellite: .satellite
    }
  }
}
