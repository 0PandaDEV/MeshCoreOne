import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Renders static `MKMapSnapshotter` thumbnails, compositing pin views (and,
/// for paths, a polyline) over the base map. `@MainActor`: `MKMapSnapshotter`
/// is non-`Sendable`, and pin sprites are rasterized from the same SwiftUI
/// `MapPinView` the live map uses (via `ImageRenderer`), which needs the main
/// actor. The compositing itself runs inside the snapshotter's completion
/// handler rather than being handed back across the `await` boundary: the
/// `MKMapSnapshotter.Snapshot` it produces isn't `Sendable`, so only the
/// finished `UIImage` ever crosses back to the awaiting call.
@MainActor
final class MapSnapshotRenderer: MapSnapshotRendering {
  /// Span for a single-coordinate snapshot, framing roughly a neighborhood —
  /// no exact MapKit equivalent to a GL zoom level, so this is tuned visually.
  private static let singlePointSpanDelta: CLLocationDegrees = 0.01

  func render(_ request: MapSnapshotRequest) async -> UIImage? {
    let coordinate = CLLocationCoordinate2D(latitude: request.latitude, longitude: request.longitude)
    let region = MKCoordinateRegion(
      center: coordinate,
      span: MKCoordinateSpan(latitudeDelta: Self.singlePointSpanDelta, longitudeDelta: Self.singlePointSpanDelta)
    )
    let sprite = Self.pinSprite(for: .droppedPin)
    let options = Self.makeOptions(region: region, isDark: request.isDark)

    return await start(MKMapSnapshotter(options: options)) { snapshot in
      UIGraphicsImageRenderer(size: snapshot.image.size).image { _ in
        snapshot.image.draw(at: .zero)
        Self.draw(sprite: sprite, at: snapshot.point(for: coordinate))
      }
    }
  }

  /// Renders a static thumbnail of a plotted location path: the polyline plus its
  /// pins, framed to the path's bounding region. A single-point path falls back
  /// to the standard centered single-pin render.
  func render(points: [MapPoint], line: MapLine?, isDark: Bool, isOffline: Bool) async -> UIImage? {
    guard let first = points.first else { return nil }
    let coordinates = points.map(\.coordinate)
    guard coordinates.count > 1, let region = coordinates.boundingRegion() else {
      return await render(MapSnapshotRequest(
        latitude: first.coordinate.latitude,
        longitude: first.coordinate.longitude,
        isDark: isDark,
        isOffline: isOffline
      ))
    }

    let pins = points.map { point in
      (coordinate: point.coordinate, sprite: Self.pinSprite(for: point.pinStyle))
    }
    let lineCoordinates = line.map(\.coordinates)
    let casingColor = UIColor.white.withAlphaComponent(Self.pathCasingOpacity)
    let options = Self.makeOptions(region: region, isDark: isDark)

    return await start(MKMapSnapshotter(options: options)) { snapshot in
      UIGraphicsImageRenderer(size: snapshot.image.size).image { context in
        snapshot.image.draw(at: .zero)
        let cgContext = context.cgContext
        if let lineCoordinates, lineCoordinates.count > 1 {
          // Mirrors the live map's `.messagePath` styling: a white casing stroked
          // under a solid blue line, round joins and caps, no dashes.
          let path = CGMutablePath()
          path.addLines(between: lineCoordinates.map { snapshot.point(for: $0) })
          cgContext.setLineJoin(.round)
          cgContext.setLineCap(.round)
          cgContext.addPath(path)
          cgContext.setStrokeColor(casingColor.cgColor)
          cgContext.setLineWidth(Self.pathCasingWidth)
          cgContext.strokePath()
          cgContext.addPath(path)
          cgContext.setStrokeColor(UIColor.systemBlue.cgColor)
          cgContext.setLineWidth(Self.pathLineWidth)
          cgContext.strokePath()
        }
        for pin in pins {
          Self.draw(sprite: pin.sprite, at: snapshot.point(for: pin.coordinate))
        }
      }
    }
  }

  // MARK: - Snapshotting

  private static func makeOptions(region: MKCoordinateRegion, isDark: Bool) -> MKMapSnapshotter.Options {
    let options = MKMapSnapshotter.Options()
    options.region = region
    options.size = CGSize(width: MapSnapshotLayout.width, height: MapSnapshotLayout.height)
    options.mapType = .standard
    options.showsBuildings = false
    options.traitCollection = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
    return options
  }

  /// Starts the snapshotter and composites its result inside the completion
  /// handler, so only the finished (Sendable-safe) `UIImage` crosses back to
  /// the awaiting caller — never the non-`Sendable` `Snapshot` itself.
  private func start(
    _ snapshotter: MKMapSnapshotter,
    compose: @escaping @Sendable (MKMapSnapshotter.Snapshot) -> UIImage?
  ) async -> UIImage? {
    let snapshotterRef = SnapshotterRef(snapshotter)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
        snapshotter.start { snapshot, _ in
          guard let snapshot else {
            continuation.resume(returning: nil)
            return
          }
          continuation.resume(returning: compose(snapshot))
        }
      }
    } onCancel: { [snapshotterRef] in
      Task { @MainActor in snapshotterRef.snapshotter.cancel() }
    }
  }

  // MARK: - Pin sprites

  /// Rasterizes the same SwiftUI pin view the live map uses, so a snapshot
  /// thumbnail's pin always matches the live map's — one rendering path
  /// instead of two kept manually in sync.
  private static func pinSprite(for style: MapPoint.PinStyle) -> UIImage {
    let resolvedStyle: MapPoint.PinStyle = switch style {
    case .pointA, .pointB: style
    default: .droppedPin
    }
    let renderer = ImageRenderer(content: MapPinView(style: resolvedStyle, hopIndex: nil, isDarkMode: false))
    renderer.scale = UIScreen.main.scale
    return renderer.uiImage ?? UIImage()
  }

  /// Draws a bottom-anchored pin sprite so its tip sits on the coordinate.
  private nonisolated static func draw(sprite: UIImage, at point: CGPoint) {
    sprite.draw(in: CGRect(
      x: point.x - sprite.size.width / 2,
      y: point.y - sprite.size.height,
      width: sprite.size.width,
      height: sprite.size.height
    ))
  }

  // MARK: - Path styling

  /// Mirrors the live map's `.messagePath` line styling.
  private nonisolated static let pathCasingOpacity: CGFloat = 0.8
  private nonisolated static let pathCasingWidth: CGFloat = 6
  private nonisolated static let pathLineWidth: CGFloat = 3
}

/// `@unchecked Sendable` shuttle so the cancellation closure (which is
/// `@Sendable`) can carry the non-`Sendable` `MKMapSnapshotter` reference
/// across actors. The closure only reads the property and immediately hops
/// back to the main actor before touching it.
private final class SnapshotterRef: @unchecked Sendable {
  let snapshotter: MKMapSnapshotter
  init(_ snapshotter: MKMapSnapshotter) {
    self.snapshotter = snapshotter
  }
}
