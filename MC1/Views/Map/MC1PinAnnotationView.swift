import MapKit
import SwiftUI

/// Custom annotation view hosting the app's SwiftUI pin content (`MapPinView`)
/// inside a native `MKAnnotationView`, so MapKit's own clustering engine
/// (`clusteringIdentifier`) groups pins natively — the same mechanism this
/// app's original Apple Maps implementation used, just retargeted at the
/// current `MapPoint` domain model instead of per-feature annotation types.
///
/// Taps fire through a plain `UITapGestureRecognizer` on the view itself
/// rather than MapKit's `didSelect` delegate callback, which carries a
/// ~300ms recognition delay.
final class MC1PinAnnotationView: MKAnnotationView {
  static let reuseIdentifier = "MC1PinAnnotationView"

  var onTap: (() -> Void)?

  private var hostingController: UIHostingController<AnyView>?

  override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    canShowCallout = false

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tap)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func handleTap() {
    onTap?()
  }

  func configure(point: MapPoint, isDarkMode: Bool, showsLabel: Bool) {
    let content = AnyView(pinContent(point: point, isDarkMode: isDarkMode, showsLabel: showsLabel))

    let hosting: UIHostingController<AnyView>
    if let existing = hostingController {
      hosting = existing
      hosting.rootView = content
    } else {
      hosting = UIHostingController(rootView: content)
      hosting.view.backgroundColor = .clear
      addSubview(hosting.view)
      hostingController = hosting
    }

    let size = hosting.sizeThatFits(in: CGSize(width: 300, height: 300))
    hosting.view.frame = CGRect(origin: .zero, size: size)
    bounds = CGRect(origin: .zero, size: size)
    centerOffset = anchorOffset(for: point.pinStyle, size: size)

    clusteringIdentifier = point.isClusterable ? Self.clusteringIdentifier : nil
    displayPriority = point.isClusterable ? .defaultLow : .required
  }

  static let clusteringIdentifier = "mc1-point"

  @ViewBuilder
  private func pinContent(point: MapPoint, isDarkMode: Bool, showsLabel: Bool) -> some View {
    switch point.pinStyle {
    case .badge:
      MapPillLabel(text: point.badgeText ?? "", fontWeight: .regular)
    default:
      VStack(spacing: 2) {
        if showsLabel, let label = point.label {
          MapPillLabel(text: label)
        }
        MapPinView(style: point.pinStyle, hopIndex: point.hopIndex, isDarkMode: isDarkMode)
      }
    }
  }

  /// Bottom-anchored for teardrop pins (their tip sits on the coordinate,
  /// regardless of whether a label pill grows the content upward); center-
  /// anchored for the styles with no pointer.
  private func anchorOffset(for style: MapPoint.PinStyle, size: CGSize) -> CGPoint {
    switch style {
    case .crosshair, .obstruction, .locationFix, .badge:
      .zero
    default:
      CGPoint(x: 0, y: -size.height / 2)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onTap = nil
  }
}
