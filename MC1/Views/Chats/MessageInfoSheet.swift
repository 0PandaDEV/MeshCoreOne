import MC1Services
import SwiftUI

/// Message details sheet, opened from the bubble's context menu ("Details").
/// A focused `List` rather than the sender/type/action-buttons the context
/// menu already covers: sent/received timestamps, hop/path info, and — when
/// available — the full repeat details or hop-by-hop path.
struct MessageInfoSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let message: MessageDTO
  let senderName: String

  @State private var detent: PresentationDetent = .medium

  /// Owned per presentation so loading state never bleeds between opens.
  @State private var pathViewModel = MessagePathViewModel()
  @State private var isDetailExpanded = true
  @State private var repeats: [MessageRepeatDTO]?
  @State private var errorMessage: String?

  private var availability: MessageActionAvailability {
    MessageActionAvailability(message: message)
  }

  var body: some View {
    NavigationStack {
      List {
        Section(senderName) {
          if message.isOutgoing {
            outgoingRows
          } else {
            incomingRows
          }
        }

        if availability.showsPathDetail {
          Section {
            MessagePathDetailBlock(
              message: message,
              arrivals: arrivals,
              pathViewModel: pathViewModel,
              isDetailExpanded: $isDetailExpanded
            )
            .listRowInsets(EdgeInsets())
          }
        }
      }
      .navigationTitle(L10n.Chats.Chats.Message.Action.details)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
    }
    // A grouped List leaves its background unpainted at the medium detent until a
    // resize relayout, which .scrolls prevents, so this explicit fill stays opaque.
    .background(Color(.systemGroupedBackground).ignoresSafeArea())
    .presentationDetents([.medium, .large], selection: $detent)
    .presentationContentInteraction(.scrolls)
    .presentationBackground(.background)
    .errorAlert($errorMessage, retryAction: { Task { await loadPathExtras() } })
    .task(id: message.id) { await loadPathExtras() }
  }

  private var arrivals: [MessagePathArrival] {
    MessagePathArrivals.assemble(message: message, repeats: repeats ?? [])
  }

  private var incomingArrivalCount: Int {
    repeats == nil
      ? max(arrivals.count, MessagePathArrivals.arrivalCount(for: message))
      : arrivals.count
  }

  /// Process-lifetime store so extras survive disconnect; ServiceContainer
  /// is torn down on disconnect and must not be the read path.
  private func loadPathExtras() async {
    guard availability.showsPathDetail else { return }
    do {
      async let loadedContacts: Void = pathViewModel.loadContacts(
        dataStore: appState.offlineDataStore,
        radioID: message.radioID
      )
      guard let store = appState.offlineDataStore else {
        repeats = []
        errorMessage = L10n.Chats.Chats.Path.extrasLoadFailed
        await loadedContacts
        return
      }
      let fetched = try await store.fetchMessageRepeats(messageID: message.id)
      repeats = fetched
      await loadedContacts
    } catch is CancellationError {
      return
    } catch {
      repeats = []
      errorMessage = L10n.Chats.Chats.Path.extrasLoadFailed
    }
  }

  @ViewBuilder
  private var outgoingRows: some View {
    Text(L10n.Chats.Chats.Message.Info.sent(
      message.senderDate.formatted(date: .abbreviated, time: .standard)))
    if let rtt = message.roundTripTime {
      Text(L10n.Chats.Chats.Message.Info.roundTrip(Int(rtt)))
    }
    if message.heardRepeats > 0 {
      let word = message.heardRepeats == 1
        ? L10n.Chats.Chats.Message.Repeat.singular
        : L10n.Chats.Chats.Message.Repeat.plural
      Text(L10n.Chats.Chats.Message.Info.heardRepeats(message.heardRepeats, word))
    }
  }

  @ViewBuilder
  private var incomingRows: some View {
    let hopsText = L10n.Chats.Chats.Message.Info.hops(
      message.isDirectRouted ? L10n.Chats.Chats.Message.Hops.direct : "\(message.hopCount)"
    )
    Text(incomingArrivalCount > 1 ? "\(hopsText) · \(L10n.Chats.Chats.Path.Arrival.first)" : hopsText)
    if let hashSize = message.pathHashSizeIfKnown {
      Text(L10n.Chats.Chats.Message.Info.pathHash(hashSize))
    }
    if let snr = message.snr {
      let snrText = L10n.Chats.Chats.Message.Info.snr(
        "\(snr.formatted(.number.precision(.fractionLength(1)))) dB (\(SNRQuality(snr: snr).localizedLabel))"
      )
      Text(incomingArrivalCount > 1 ? "\(snrText) · \(L10n.Chats.Chats.Path.Arrival.first)" : snrText)
    }
    if message.routeType == .tcFlood {
      switch RegionScopeSemantics.coalesce(scope: message.regionScope, matches: message.regionScopeMatches) {
      case .none:
        Text(L10n.Chats.Chats.Message.Info.regionUnresolved)
      case let .unique(name):
        Text(L10n.Chats.Chats.Message.Info.floodedUnder(name))
      case let .ambiguous(names):
        Text(L10n.Chats.Chats.Message.Info.regionAmbiguous(ListFormatter.localizedString(byJoining: names)))
      }
    }
    Text(L10n.Chats.Chats.Message.Info.sent(
      message.senderDate.formatted(date: .abbreviated, time: .standard))
      + (message.timestampCorrected ? " \(L10n.Chats.Chats.Message.Info.adjusted)" : ""))
    if message.timestampCorrected {
      Text(L10n.Chats.Chats.Message.Info.originalSendTime(
        message.wireSentDate.formatted(date: .abbreviated, time: .standard)))
    }
    Text(L10n.Chats.Chats.Message.Info.received(
      message.createdAt.formatted(date: .abbreviated, time: .standard)))
  }
}
