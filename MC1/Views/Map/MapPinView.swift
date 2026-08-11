import SwiftUI

/// Renders a `MapPoint` as a native SwiftUI annotation view. Replaces the old
/// MapLibre sprite-bitmap system (`PinSpriteRenderer`) one-for-one visually —
/// same colors, sizes, rings, and hop badges — but as plain SwiftUI content
/// handed straight to a MapKit `Annotation`, with no sprite registry needed.
struct MapPinView: View {
  let style: MapPoint.PinStyle
  let hopIndex: Int?
  let isDarkMode: Bool

  var body: some View {
    switch style {
    case .crosshair:
      MapCrosshairPinView()
    case .obstruction:
      MapObstructionPinView()
    case .locationFix:
      MapLocationDotView(bucket: hopIndex ?? 0, isDarkMode: isDarkMode)
    case .badge:
      EmptyView() // Badges render via MapBadgeView directly from `badgeText`.
    default:
      if let visual = style.teardropVisual {
        MapTeardropPinView(visual: visual, hopBadge: hopBadge)
      }
    }
  }

  /// Only the ring-white and plain hop styles overhang a hop-count badge;
  /// the blue/green ring states never did in the original sprite set.
  private var hopBadge: Int? {
    guard let hopIndex, hopIndex > 0 else { return nil }
    switch style {
    case .repeaterRingWhite, .repeaterHop: return min(hopIndex, MapPinMetrics.maxHopBadge)
    default: return nil
    }
  }
}

/// Largest hop number a pin badge renders; hops beyond this clamp to the cap.
/// MeshCore paths top out at 64 hops.
enum MapPinMetrics {
  static let maxHopBadge = 64
  static let circleDiameter: CGFloat = 36
  static let triangleHeight: CGFloat = 10
  static let triangleWidth: CGFloat = 10
  static let triangleOverlap: CGFloat = 3
  static let ringDiameter: CGFloat = 44
  static let ringLineWidth: CGFloat = 3
  static let iconSize: CGFloat = 16
  static let centerDotDiameter: CGFloat = 12
  static let hopBadgeDiameter: CGFloat = 18
  static let locationDotDiameter: CGFloat = 14

  /// Number of recency buckets a location trail's dots are graded into. Five
  /// reads as a clear directional gradient without banding into noise at dot
  /// size. `nonisolated` so the (non-isolated) path builder can bucket against it.
  nonisolated static let recencyBucketCount = 5

  /// Full pin height (circle + pointer), used to lift a callout above the tip.
  static let standardHeight: CGFloat = circleDiameter + triangleHeight - triangleOverlap

  /// Upward offset from a pin's coordinate to where its tap callout should
  /// attach: the top of the drawn pin. Bottom-anchored teardrops lift a full
  /// pin height; the center-anchored location dot lifts only its radius plus
  /// a hair of clearance.
  static func calloutLift(for style: MapPoint.PinStyle) -> CGFloat {
    switch style {
    case .locationFix: locationDotDiameter / 2 + 4
    default: standardHeight
    }
  }
}

// MARK: - Teardrop pin (contacts, repeaters, LOS points, dropped pins)

/// Visual recipe for a standard teardrop pin: filled circle + downward pointer.
struct MapPinVisual {
  let circleColor: Color
  let iconName: String?
  let text: String?
  let centerDot: Bool
  let ringColor: Color?

  init(
    circleColor: Color,
    iconName: String? = nil,
    text: String? = nil,
    centerDot: Bool = false,
    ringColor: Color? = nil
  ) {
    self.circleColor = circleColor
    self.iconName = iconName
    self.text = text
    self.centerDot = centerDot
    self.ringColor = ringColor
  }
}

extension MapPoint.PinStyle {
  /// The hero tint for a node's latest location report.
  private static let locationHeroColor = Color(red: 0xFF / 255, green: 0x37 / 255, blue: 0x5F / 255)

  var teardropVisual: MapPinVisual? {
    switch self {
    case .contactChat:
      MapPinVisual(circleColor: Color(red: 204 / 255, green: 122 / 255, blue: 92 / 255), iconName: "person.fill")
    case .contactRepeater, .repeater:
      MapPinVisual(circleColor: .cyan, iconName: "antenna.radiowaves.left.and.right")
    case .contactRoom:
      MapPinVisual(circleColor: Color(red: 1, green: 136 / 255, blue: 0), iconName: "person.3.fill")
    case .repeaterRingBlue:
      MapPinVisual(circleColor: .cyan, iconName: "antenna.radiowaves.left.and.right", ringColor: .blue)
    case .repeaterRingGreen:
      MapPinVisual(circleColor: .cyan, iconName: "antenna.radiowaves.left.and.right", ringColor: .green)
    case .repeaterRingWhite:
      MapPinVisual(circleColor: .cyan, iconName: "antenna.radiowaves.left.and.right", ringColor: .white)
    case .repeaterHop:
      MapPinVisual(circleColor: .cyan, iconName: "antenna.radiowaves.left.and.right")
    case .pointA:
      MapPinVisual(circleColor: .blue, text: "A")
    case .pointB:
      MapPinVisual(circleColor: .green, text: "B")
    case .droppedPin:
      MapPinVisual(circleColor: .pink, iconName: "mappin")
    case .locationFixLatest:
      MapPinVisual(circleColor: Self.locationHeroColor, centerDot: true)
    case .crosshair, .obstruction, .badge, .locationFix:
      nil
    }
  }
}

private struct MapTeardropPinView: View {
  let visual: MapPinVisual
  let hopBadge: Int?

  var body: some View {
    ZStack(alignment: .top) {
      if let ringColor = visual.ringColor {
        Circle()
          .stroke(ringColor, lineWidth: MapPinMetrics.ringLineWidth)
          .frame(width: MapPinMetrics.ringDiameter, height: MapPinMetrics.ringDiameter)
      }

      VStack(spacing: -MapPinMetrics.triangleOverlap) {
        ZStack {
          Circle()
            .fill(visual.circleColor)
            .frame(width: MapPinMetrics.circleDiameter, height: MapPinMetrics.circleDiameter)
          content
        }
        TeardropTriangle()
          .fill(visual.circleColor)
          .frame(width: MapPinMetrics.triangleWidth, height: MapPinMetrics.triangleHeight)
      }
      .compositingGroup()
      .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)

      if let hopBadge {
        HopBadgeView(number: hopBadge)
          .offset(
            x: MapPinMetrics.circleDiameter / 2 - MapPinMetrics.hopBadgeDiameter / 2 + 2,
            y: -MapPinMetrics.hopBadgeDiameter / 2 + 2
          )
      }
    }
    .frame(
      width: max(MapPinMetrics.ringDiameter, MapPinMetrics.circleDiameter),
      height: MapPinMetrics.standardHeight,
      alignment: .top
    )
  }

  @ViewBuilder
  private var content: some View {
    if let iconName = visual.iconName {
      Image(systemName: iconName)
        .font(.system(size: MapPinMetrics.iconSize))
        .foregroundStyle(.white)
    } else if let text = visual.text {
      Text(text)
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(.white)
    } else if visual.centerDot {
      Circle()
        .fill(.white)
        .frame(width: MapPinMetrics.centerDotDiameter, height: MapPinMetrics.centerDotDiameter)
    }
  }
}

/// Downward-pointing triangle, the teardrop pin's tail.
private struct TeardropTriangle: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

private struct HopBadgeView: View {
  let number: Int

  var body: some View {
    Text("\(number)")
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: MapPinMetrics.hopBadgeDiameter, height: MapPinMetrics.hopBadgeDiameter)
      .background(Circle().fill(.blue))
  }
}

// MARK: - Crosshair (LOS target / repeater marker)

private struct MapCrosshairPinView: View {
  private let outerRadius: CGFloat = 22
  private let gapRadius: CGFloat = 4

  var body: some View {
    VStack(spacing: 2) {
      ZStack {
        CrosshairShape(outerRadius: outerRadius, gapRadius: gapRadius)
          .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
        CrosshairShape(outerRadius: outerRadius, gapRadius: gapRadius)
          .stroke(.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round))
      }
      .frame(width: outerRadius * 2, height: outerRadius * 2)

      Text("R")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(RoundedRectangle(cornerRadius: 9).fill(.purple))
    }
  }
}

private struct CrosshairShape: Shape {
  let outerRadius: CGFloat
  let gapRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    var path = Path()
    path.move(to: CGPoint(x: center.x, y: center.y - outerRadius))
    path.addLine(to: CGPoint(x: center.x, y: center.y - gapRadius))
    path.move(to: CGPoint(x: center.x, y: center.y + gapRadius))
    path.addLine(to: CGPoint(x: center.x, y: center.y + outerRadius))
    path.move(to: CGPoint(x: center.x - outerRadius, y: center.y))
    path.addLine(to: CGPoint(x: center.x - gapRadius, y: center.y))
    path.move(to: CGPoint(x: center.x + gapRadius, y: center.y))
    path.addLine(to: CGPoint(x: center.x + outerRadius, y: center.y))
    return path
  }
}

// MARK: - Obstruction marker (LOS)

private struct MapObstructionPinView: View {
  private let armLength: CGFloat = 9

  var body: some View {
    ObstructionXShape(armLength: armLength)
      .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
      .overlay {
        ObstructionXShape(armLength: armLength)
          .stroke(.red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
      }
      .frame(width: 26, height: 26)
  }
}

private struct ObstructionXShape: Shape {
  let armLength: CGFloat

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    var path = Path()
    path.move(to: CGPoint(x: center.x - armLength, y: center.y - armLength))
    path.addLine(to: CGPoint(x: center.x + armLength, y: center.y + armLength))
    path.move(to: CGPoint(x: center.x + armLength, y: center.y - armLength))
    path.addLine(to: CGPoint(x: center.x - armLength, y: center.y + armLength))
    return path
  }
}

// MARK: - Location-fix recency dot

/// One sampled node-location report threaded onto a history trail: a small
/// filled dot, center-anchored (no teardrop pointer). Color grades by recency
/// bucket (oldest → newest) through a warm "ember" ramp that stops short of the
/// hero pink, so the newest trail dot is never mistaken for the current-position
/// hero pin. Tuned separately per basemap theme for contrast; rises in
/// saturation and warmth together for greyscale/colorblind legibility.
struct MapLocationDotView: View {
  let bucket: Int
  let isDarkMode: Bool

  private static let paletteLight = [0xA19687, 0xB68F68, 0xD17A47, 0xE76740, 0xF55E47].map(hexColor)
  private static let paletteDark = [0xB1A695, 0xC59E77, 0xD8885A, 0xED7C5A, 0xF87662].map(hexColor)

  private nonisolated static func hexColor(_ hex: UInt32) -> Color {
    Color(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }

  private var fill: Color {
    let palette = isDarkMode ? Self.paletteDark : Self.paletteLight
    let clamped = min(max(bucket, 0), palette.count - 1)
    return palette[clamped]
  }

  /// A pure-white casing on a dark basemap sparkles and starts borrowing the
  /// hero's white-center language, so soften it there.
  private var casing: Color {
    isDarkMode ? .white.opacity(0.85) : .white
  }

  var body: some View {
    Circle()
      .fill(fill)
      .overlay(Circle().stroke(casing, lineWidth: 2))
      .frame(width: MapPinMetrics.locationDotDiameter, height: MapPinMetrics.locationDotDiameter)
      .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
  }
}

// MARK: - Pill label / badge

/// Shared pill chrome for name labels and SNR/distance badges: translucent
/// white background, soft shadow, rounded corners.
struct MapPillLabel: View {
  let text: String
  var textColor: Color = .black
  var fontWeight: Font.Weight = .bold

  var body: some View {
    Text(text)
      .font(.system(size: 12, weight: fontWeight))
      .foregroundStyle(textColor)
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(.white.opacity(0.85))
          .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
      )
  }
}
