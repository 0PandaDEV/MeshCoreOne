import MapKit
import UIKit

/// `MKPolyline` subclass carrying the `MapLine` styling data an
/// `MC1LineRenderer` needs to draw it. `MKPolyline`'s coordinate storage is
/// otherwise opaque, so the style/opacity/id ride along as separate
/// properties set right after the designated initializer.
final class MC1LineOverlay: MKPolyline {
  private(set) var lineID = ""
  private(set) var lineStyle: MapLine.LineStyle = .los
  private(set) var lineOpacity: Double = 1

  static func make(from line: MapLine) -> MC1LineOverlay {
    var coords = line.coordinates
    let overlay = MC1LineOverlay(coordinates: &coords, count: coords.count)
    overlay.lineID = line.id
    overlay.lineStyle = line.style
    overlay.lineOpacity = line.opacity
    return overlay
  }
}

/// Draws an `MC1LineOverlay` as a casing pass (wider, white) under a color
/// pass, mirroring the live map's line styling for every `MapLine.LineStyle`.
/// A plain `MKPolylineRenderer` only supports one stroke, so this overrides
/// `draw` to stroke the path twice with `MapLineStrokeConfig`'s widths/dashes,
/// converting each points-based width to map-point space via `zoomScale`.
final class MC1LineRenderer: MKOverlayRenderer {
  private let config: MapLineStrokeConfig
  private let opacity: Double

  init(overlay: MC1LineOverlay) {
    config = overlay.lineStyle.strokeConfig
    opacity = overlay.lineOpacity
    super.init(overlay: overlay)
  }

  override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
    guard let polyline = overlay as? MKPolyline, polyline.pointCount > 1 else { return }
    let path = path(for: polyline)

    context.saveGState()
    context.setAlpha(opacity)
    context.setLineJoin(.round)
    context.setLineCap(.round)

    stroke(path, color: UIColor(MapLineStrokeConfig.casingColor), width: config.casingWidth, dash: config.casingDash, zoomScale: zoomScale, in: context)
    stroke(path, color: UIColor(config.color), width: config.width, dash: config.dash, zoomScale: zoomScale, in: context)

    context.restoreGState()
  }

  private func stroke(
    _ path: CGPath,
    color: UIColor,
    width: CGFloat,
    dash: [CGFloat],
    zoomScale: MKZoomScale,
    in context: CGContext
  ) {
    context.addPath(path)
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(width / zoomScale)
    context.setLineDash(phase: 0, lengths: dash.map { $0 / zoomScale })
    context.strokePath()
  }

  private func path(for polyline: MKPolyline) -> CGPath {
    let mapPoints = polyline.points()
    let path = CGMutablePath()
    for index in 0..<polyline.pointCount {
      let screenPoint = point(for: mapPoints[index])
      if index == 0 {
        path.move(to: screenPoint)
      } else {
        path.addLine(to: screenPoint)
      }
    }
    return path
  }
}
