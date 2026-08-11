import MapKit
import UIKit

/// Native cluster bubble for grouped `MapPoint` pins: a filled circle sized
/// by member count with a centered count label. `MKMapView` drives the
/// grouping itself (`MKClusterAnnotation`) — this view only renders the
/// result, which is what makes the grouping/expansion animate smoothly.
final class MC1ClusterAnnotationView: MKAnnotationView {
  private let countLabel = UILabel()
  private let circleView = UIView()

  override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    circleView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
    circleView.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
    circleView.layer.borderWidth = 2
    addSubview(circleView)

    countLabel.font = .systemFont(ofSize: 13)
    countLabel.textColor = .white
    countLabel.textAlignment = .center
    circleView.addSubview(countLabel)

    canShowCallout = false
    displayPriority = .required
    collisionMode = .circle
  }

  func configure(with cluster: MKClusterAnnotation) {
    let count = cluster.memberAnnotations.count
    let size = diameter(for: count)

    circleView.frame = CGRect(x: 0, y: 0, width: size, height: size)
    circleView.layer.cornerRadius = size / 2
    countLabel.frame = circleView.bounds
    countLabel.text = "\(count)"

    frame = CGRect(x: 0, y: 0, width: size, height: size)
    centerOffset = .zero

    isAccessibilityElement = true
    accessibilityLabel = L10n.Map.Map.Cluster.label(count)
    accessibilityHint = L10n.Map.Map.Cluster.hint
    accessibilityTraits = .button
  }

  private func diameter(for count: Int) -> CGFloat {
    switch count {
    case ..<50: 36
    case 50..<100: 48
    case 100..<200: 60
    default: 76
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    countLabel.text = nil
    accessibilityLabel = nil
    accessibilityHint = nil
  }

  override func prepareForDisplay() {
    super.prepareForDisplay()
    if let cluster = annotation as? MKClusterAnnotation {
      configure(with: cluster)
    }
  }
}
