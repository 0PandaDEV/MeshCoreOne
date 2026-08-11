import MapKit
import SwiftUI

/// `UIViewRepresentable` wrapping `MKMapView` — native Apple Maps with native
/// `MKAnnotationView.clusteringIdentifier`/`MKClusterAnnotation` grouping and
/// gesture-based immediate-response pin taps (bypassing MapKit's ~300ms
/// `didSelect` delay). Ported from this app's original MapKit implementation
/// (before a since-reverted MapLibre migration), generalized to render the
/// current `MapPoint`/`MapLine` domain model instead of feature-specific
/// annotation types, so one wrapper serves every map screen.
struct MC1MapView: UIViewRepresentable {
  // Data
  let points: [MapPoint]
  let lines: [MapLine]
  let mapStyle: MapStyleSelection
  let isDarkMode: Bool

  // Configuration
  let showLabels: Bool
  let showsUserLocation: Bool
  let isInteractive: Bool
  let showsScale: Bool
  var isNorthLocked: Bool = false

  // Camera. The version counters mirror value-binding-driven "apply once per
  // bump" reactivity: plain bindings don't tell us *when* a new target
  // arrived, only what it currently is.
  @Binding var cameraRegion: MKCoordinateRegion?
  let cameraRegionVersion: Int
  /// Fraction of the bottom of the screen covered by a sheet/panel, so the
  /// applied region frames its content in the remaining visible area instead
  /// of centering across the whole screen including the obscured strip.
  var cameraBottomSheetFraction: CGFloat?

  // Programmatic selection: the id of the point to select, plus a version
  // counter bumped to (re)fire it. Routed through `onPointTap`, so a
  // programmatic selection presents the callout exactly like a user tap.
  var selectionRequestID: UUID?
  var selectionRequestVersion: Int = 0

  /// The point whose callout/popover is currently showing. That pin's own
  /// persistent name pill is suppressed while showing — otherwise the name
  /// reads twice (once above the pin, once in the callout right next to it).
  var selectedPointID: UUID?

  // Output callbacks
  let onPointTap: ((MapPoint, CGPoint) -> Void)?
  let onMapTap: ((CLLocationCoordinate2D) -> Void)?
  var onMapLongPress: ((CLLocationCoordinate2D) -> Void)?
  let onCameraRegionChange: ((MKCoordinateRegion) -> Void)?

  /// Optional features
  var isStyleLoaded: Binding<Bool> = .constant(true)

  /// Reports whether the camera is currently centered on the user's location.
  var isCenteredOnUser: Binding<Bool> = .constant(false)

  func makeUIView(context: Context) -> MKMapView {
    let mapView = context.coordinator.mapView
    mapView.delegate = context.coordinator
    mapView.showsUserLocation = showsUserLocation
    mapView.showsCompass = true
    mapView.showsScale = showsScale

    mapView.register(
      MC1PinAnnotationView.self,
      forAnnotationViewWithReuseIdentifier: MC1PinAnnotationView.reuseIdentifier
    )
    mapView.register(
      MC1ClusterAnnotationView.self,
      forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
    )

    if !isInteractive {
      mapView.isScrollEnabled = false
      mapView.isZoomEnabled = false
      mapView.isRotateEnabled = false
      mapView.isPitchEnabled = false
    }

    let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
    tap.delegate = context.coordinator
    mapView.addGestureRecognizer(tap)

    let longPress = UILongPressGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleLongPress(_:))
    )
    longPress.delegate = context.coordinator
    mapView.addGestureRecognizer(longPress)

    context.coordinator.isStyleLoaded = { isStyleLoaded.wrappedValue = true }
    context.coordinator.isStyleLoaded?()

    return mapView
  }

  static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
    coordinator.pendingRegionTask?.cancel()
    mapView.delegate = nil
  }

  func updateUIView(_ mapView: MKMapView, context: Context) {
    let coordinator = context.coordinator
    coordinator.isUpdatingFromSwiftUI = true
    defer { coordinator.isUpdatingFromSwiftUI = false }

    coordinator.onPointTap = onPointTap
    coordinator.onMapTap = onMapTap
    coordinator.onMapLongPress = onMapLongPress
    coordinator.onCameraRegionChange = onCameraRegionChange
    coordinator.setIsCenteredOnUser = { isCenteredOnUser.wrappedValue = $0 }
    coordinator.isDarkMode = isDarkMode
    coordinator.showLabels = showLabels
    coordinator.selectedPointID = selectedPointID
    coordinator.currentPoints = points

    mapView.mapType = mapStyle.mapType
    mapView.overrideUserInterfaceStyle = isDarkMode ? .dark : .light

    if mapView.showsUserLocation != showsUserLocation {
      mapView.showsUserLocation = showsUserLocation
    }

    if isInteractive {
      mapView.isRotateEnabled = !isNorthLocked
      if isNorthLocked, mapView.camera.heading != 0 {
        let camera = mapView.camera
        camera.heading = 0
        mapView.setCamera(camera, animated: true)
      }
    }

    coordinator.updatePointAnnotations(points, in: mapView)
    coordinator.updateLineOverlays(lines, in: mapView)
    coordinator.refreshVisiblePinViews(in: mapView)
    updateCameraRegion(in: mapView, coordinator: coordinator)

    if coordinator.lastAppliedSelectionVersion != selectionRequestVersion {
      coordinator.lastAppliedSelectionVersion = selectionRequestVersion
      if let id = selectionRequestID, let point = points.first(where: { $0.id == id }) {
        DispatchQueue.main.async { coordinator.selectPoint(point, in: mapView) }
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  // MARK: - Camera

  private func updateCameraRegion(in mapView: MKMapView, coordinator: Coordinator) {
    guard let region = cameraRegion, cameraRegionVersion != coordinator.lastAppliedRegionVersion else { return }
    guard CLLocationCoordinate2DIsValid(region.center),
          region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite,
          region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else {
      coordinator.lastAppliedRegionVersion = cameraRegionVersion
      return
    }

    let animated = coordinator.lastAppliedRegionVersion >= 0
    coordinator.lastAppliedRegionVersion = cameraRegionVersion
    let adjusted = regionAccountingForBottomSheet(region)
    coordinator.hasPendingProgrammaticRegion = true
    coordinator.lastAppliedRegion = adjusted
    mapView.setRegion(mapView.regionThatFits(adjusted), animated: animated)
  }

  /// Inflates and shifts the region so its content frames within the visible
  /// (non-sheet-covered) top portion of the screen, rather than being
  /// centered across the whole screen including the obscured bottom strip.
  private func regionAccountingForBottomSheet(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
    guard let fraction = cameraBottomSheetFraction, fraction > 0, fraction < 1 else { return region }
    let scale = 1 / (1 - fraction)
    let newLatDelta = min(region.span.latitudeDelta * scale, 170)
    let latShift = (newLatDelta - region.span.latitudeDelta) / 2
    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: min(85, region.center.latitude + latShift),
        longitude: region.center.longitude
      ),
      span: MKCoordinateSpan(latitudeDelta: newLatDelta, longitudeDelta: region.span.longitudeDelta)
    )
  }

  // MARK: - Coordinator

  @MainActor
  final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
    lazy var mapView: MKMapView = NoDoubleTapMapView()

    // Callbacks
    var onPointTap: ((MapPoint, CGPoint) -> Void)?
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    var onMapLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onCameraRegionChange: ((MKCoordinateRegion) -> Void)?
    var setIsCenteredOnUser: ((Bool) -> Void)?
    var isStyleLoaded: (() -> Void)?

    // Configuration mirrored from the representable each update
    var isDarkMode = false
    var showLabels = true
    var selectedPointID: UUID?
    var currentPoints: [MapPoint] = []

    // State
    var isUpdatingFromSwiftUI = false
    var lastAppliedRegion: MKCoordinateRegion?
    var lastAppliedRegionVersion = -1
    var lastAppliedSelectionVersion = 0
    var pendingRegionTask: Task<Void, Never>?
    private var hasPendingProgrammaticRegionInternal = false
    var hasPendingProgrammaticRegion: Bool {
      get { hasPendingProgrammaticRegionInternal }
      set { hasPendingProgrammaticRegionInternal = newValue }
    }
    private var hasReceivedInitialRegion = false

    // MARK: - Annotation diffing

    func updatePointAnnotations(_ points: [MapPoint], in mapView: MKMapView) {
      let existing = mapView.annotations.compactMap { $0 as? MapPointAnnotation }
      var existingByID: [UUID: MapPointAnnotation] = [:]
      for annotation in existing { existingByID[annotation.point.id] = annotation }

      let newIDs = Set(points.map(\.id))
      let toRemove = existing.filter { !newIDs.contains($0.point.id) }
      if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }

      var toAdd: [MapPointAnnotation] = []
      var toReAdd: [MapPointAnnotation] = []
      for point in points {
        if let current = existingByID[point.id] {
          if current.point != point {
            // Content changed (label, hopIndex, badgeText, clusterability, style).
            // MapKit doesn't pick up clusteringIdentifier/coordinate changes on an
            // existing annotation, so remove and re-add rather than mutate in place.
            toReAdd.append(MapPointAnnotation(point: point))
          }
        } else {
          toAdd.append(MapPointAnnotation(point: point))
        }
      }
      if !toReAdd.isEmpty {
        let staleIDs = Set(toReAdd.map(\.point.id))
        mapView.removeAnnotations(existing.filter { staleIDs.contains($0.point.id) })
      }
      let combined = toAdd + toReAdd
      if !combined.isEmpty { mapView.addAnnotations(combined) }
    }

    /// Applies label/selection changes to already-placed pin views without an
    /// add/remove pass, so toggling "Show Labels" or opening a callout doesn't
    /// re-trigger clustering.
    func refreshVisiblePinViews(in mapView: MKMapView) {
      for annotation in mapView.annotations {
        guard let pointAnnotation = annotation as? MapPointAnnotation,
              let view = mapView.view(for: pointAnnotation) as? MC1PinAnnotationView else { continue }
        let showsLabel = showLabels && pointAnnotation.point.id != selectedPointID
        view.configure(point: pointAnnotation.point, isDarkMode: isDarkMode, showsLabel: showsLabel)
      }
    }

    func updateLineOverlays(_ lines: [MapLine], in mapView: MKMapView) {
      let existing = mapView.overlays.compactMap { $0 as? MC1LineOverlay }
      guard !linesMatch(lines, existing) else { return }
      mapView.removeOverlays(existing)
      mapView.addOverlays(lines.map(MC1LineOverlay.make(from:)))
    }

    private func linesMatch(_ lines: [MapLine], _ overlays: [MC1LineOverlay]) -> Bool {
      guard lines.count == overlays.count else { return false }
      return zip(lines, overlays).allSatisfy { line, overlay in
        line.id == overlay.lineID && line.style == overlay.lineStyle && line.opacity == overlay.lineOpacity
      }
    }

    // MARK: - Selection

    func selectPoint(_ point: MapPoint, in mapView: MKMapView) {
      guard let annotation = mapView.annotations
        .compactMap({ $0 as? MapPointAnnotation })
        .first(where: { $0.point.id == point.id }),
        let view = mapView.view(for: annotation) else { return }
      let anchorPoint = view.convert(CGPoint(x: view.bounds.midX, y: 0), to: mapView)
      onPointTap?(point, anchorPoint)
    }

    // MARK: - Gestures

    @objc func handleTap(_ sender: UITapGestureRecognizer) {
      guard sender.state == .ended else { return }
      let point = sender.location(in: mapView)
      let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
      onMapTap?(coordinate)
    }

    @objc func handleLongPress(_ sender: UILongPressGestureRecognizer) {
      guard sender.state == .began else { return }
      let point = sender.location(in: mapView)
      let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
      onMapLongPress?(coordinate)
    }

    /// Lets pin-view taps (a separate gesture recognizer on the annotation
    /// view itself) win over the map's own background tap/long-press, so
    /// tapping a pin never also dismisses/re-triggers the background handler.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      !(touch.view is MKAnnotationView) && !(touch.view?.superview is MKAnnotationView)
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
      if annotation is MKUserLocation { return nil }

      if let cluster = annotation as? MKClusterAnnotation {
        let view = mapView.dequeueReusableAnnotationView(
          withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
          for: annotation
        ) as? MC1ClusterAnnotationView ?? MC1ClusterAnnotationView(
          annotation: annotation,
          reuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
        )
        view.configure(with: cluster)
        return view
      }

      guard let pointAnnotation = annotation as? MapPointAnnotation else { return nil }
      let view = mapView.dequeueReusableAnnotationView(
        withIdentifier: MC1PinAnnotationView.reuseIdentifier,
        for: annotation
      ) as? MC1PinAnnotationView ?? MC1PinAnnotationView(
        annotation: annotation,
        reuseIdentifier: MC1PinAnnotationView.reuseIdentifier
      )
      let showsLabel = showLabels && pointAnnotation.point.id != selectedPointID
      view.configure(point: pointAnnotation.point, isDarkMode: isDarkMode, showsLabel: showsLabel)
      view.onTap = { [weak self, weak mapView] in
        guard let self, let mapView else { return }
        selectPoint(pointAnnotation.point, in: mapView)
      }
      return view
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
      if let lineOverlay = overlay as? MC1LineOverlay {
        return MC1LineRenderer(overlay: lineOverlay)
      }
      return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
      mapView.deselectAnnotation(annotation, animated: false)
      if let cluster = annotation as? MKClusterAnnotation {
        mapView.showAnnotations(cluster.memberAnnotations, animated: true)
      }
    }

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
      guard !isUpdatingFromSwiftUI, hasReceivedInitialRegion, !hasPendingProgrammaticRegion else { return }
      setIsCenteredOnUser?(false)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
      guard !isUpdatingFromSwiftUI else { return }

      if hasPendingProgrammaticRegion {
        hasPendingProgrammaticRegion = false
        hasReceivedInitialRegion = true
        lastAppliedRegion = mapView.region
        return
      }

      // The first region change is from MKMapView's own initialization, not a user gesture.
      if !hasReceivedInitialRegion {
        hasReceivedInitialRegion = true
        lastAppliedRegion = mapView.region
        return
      }

      lastAppliedRegion = mapView.region

      pendingRegionTask?.cancel()
      pendingRegionTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        self.onCameraRegionChange?(mapView.region)
      }
    }
  }
}
