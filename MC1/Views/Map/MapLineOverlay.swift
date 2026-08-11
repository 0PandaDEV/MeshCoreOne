import MC1Services
import SwiftUI

/// Casing + color stroke recipe for a `MapLine.LineStyle`, mirroring the old
/// GL layer pairs one-for-one: a wider white "casing" pass drawn first, then a
/// narrower colored pass on top, giving every line a soft outline against
/// either basemap.
struct MapLineStrokeConfig {
  let casingWidth: CGFloat
  let casingDash: [CGFloat]
  let color: Color
  let width: CGFloat
  let dash: [CGFloat]

  private static let casingOpacity = 0.8
  static let casingColor = Color.white.opacity(casingOpacity)
}

extension MapLine.LineStyle {
  var strokeConfig: MapLineStrokeConfig {
    switch self {
    case .los:
      MapLineStrokeConfig(casingWidth: 6, casingDash: [0.7, 1.3], color: .blue, width: 3, dash: [1.4, 2.6])
    case .traceUntraced:
      MapLineStrokeConfig(casingWidth: 5, casingDash: [0.7, 1.3], color: .gray, width: 2, dash: [1.75, 3.25])
    case .traceWeak:
      MapLineStrokeConfig(casingWidth: 6, casingDash: [0.7, 1.3], color: SNRQuality.poor.color, width: 3, dash: [1.4, 2.6])
    case .traceMedium:
      MapLineStrokeConfig(casingWidth: 6, casingDash: [0.7, 1.3], color: SNRQuality.fair.color, width: 3, dash: [1.4, 2.6])
    case .traceGood:
      MapLineStrokeConfig(casingWidth: 7, casingDash: [], color: SNRQuality.good.color, width: 4, dash: [])
    case .messagePath:
      MapLineStrokeConfig(casingWidth: 6, casingDash: [], color: .blue, width: 3, dash: [])
    case .locationTrail:
      MapLineStrokeConfig(casingWidth: 5, casingDash: [0.8, 1.4], color: .gray, width: 2.5, dash: [1.6, 2.8])
    }
  }
}
