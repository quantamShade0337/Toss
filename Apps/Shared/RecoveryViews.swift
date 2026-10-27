import SwiftUI
import TossCore

struct RecoveryCard: View {
    let issue: DeliveryIssue
    var title: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title ?? issue.title, systemImage: "exclamationmark.circle")
                .font(.headline)
            Text(issue.guidance).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

struct RemoteDeliveryStatusView: View {
    @Environment(TossEngine.self) private var engine
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(engine.remoteIssue?.title ?? (engine.remoteAvailability == .available ? "Ready between networks" : "Checking delivery…"),
                  systemImage: engine.remoteIssue == nil && engine.remoteAvailability == .available ? "checkmark.circle" : "network")
                .font(.headline)
            Text("Paired devices must use the same iCloud account for delivery when apart.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let issue = engine.remoteIssue {
                Text(issue.guidance).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    guard !checking else { return }
                    checking = true
                    Task {
                        await engine.syncRemote()
                        await engine.flush()
                        checking = false
                    }
                } label: {
                    if checking { ProgressView().accessibilityLabel("Checking delivery") }
                    else { Label("Check Again", systemImage: "arrow.clockwise") }
                }
                .disabled(checking)
                if let date = engine.lastRemoteSync {
                    Text("Checked \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 4)
    }
}

struct StorageRecoveryView: View {
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Toss couldn't open", systemImage: "lock.shield")
        } description: {
            Text(DeliveryIssue.storage.guidance)
        } actions: {
            Button("Try Again", action: retry).buttonStyle(.borderedProminent)
        }
    }
}
