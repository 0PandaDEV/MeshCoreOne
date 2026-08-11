import Foundation
import Network

/// App-wide network reachability signal. Split out of the old `OfflineMapService`
/// when the offline map-pack system was removed (MapKit has no public API for
/// downloading map regions for offline use) — this bit, "is the network up right
/// now," is still needed on its own: map snapshot rendering (`MKMapSnapshotter`)
/// needs live network to fetch tiles it hasn't cached, so the chat snapshot
/// pipeline retries failed renders when connectivity returns.
@Observable
@MainActor
final class NetworkMonitor {
  private(set) var isNetworkAvailable = true

  private let monitor = NWPathMonitor()
  private var observationTask: Task<Void, Never>?

  init() {
    let monitor = monitor
    let networkStream = AsyncStream<NWPath> { continuation in
      continuation.onTermination = { _ in monitor.cancel() }
      monitor.pathUpdateHandler = { continuation.yield($0) }
      // NWPathMonitor requires a DispatchQueue; no Swift concurrency alternative exists.
      monitor.start(queue: .global(qos: .utility))
    }
    observationTask = Task { [weak self] in
      for await path in networkStream {
        self?.isNetworkAvailable = path.status == .satisfied
      }
    }
  }

  isolated deinit {
    monitor.cancel()
    observationTask?.cancel()
  }
}
