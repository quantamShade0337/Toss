import SwiftUI
import TossCore

struct MainTabs: View {
    @Environment(TossEngine.self) private var engine
    var body: some View {
        TabView {
            NavigationStack { InboxView().navigationDestination(for: TossRoute.self) { TossDestination(route: $0) } }
                .tabItem { Label("Inbox", systemImage: "tray") }
            NavigationStack { SendView().navigationDestination(for: TossRoute.self) { TossDestination(route: $0) } }
                .tabItem { Label("Send", systemImage: "arrow.up.right") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .alert("Toss", isPresented: Binding(get: { engine.errorMessage != nil },
                                             set: { if !$0 { engine.errorMessage = nil } })) {
            Button("OK") { engine.errorMessage = nil }
        } message: { Text(engine.errorMessage ?? "") }
    }
}

private enum InboxFilter: String, CaseIterable, Identifiable {
    case all = "All", links = "Links", files = "Files", text = "Text", images = "Images"
    var id: Self { self }
    func matches(_ kind: ContentKind) -> Bool {
        switch self {
        case .all: true
        case .links: kind == .link
        case .files: kind == .file
        case .text: [.text, .code, .event, .location, .phone, .email].contains(kind)
        case .images: kind == .image
        }
    }
}

struct InboxView: View {
    @Environment(TossEngine.self) private var engine
    @State private var filter: InboxFilter = .all
    @State private var showScanner = false

    private var items: [TransferItem] {
        engine.transfers.filter { $0.receiverDeviceID == engine.identity.id && !$0.isArchived && filter.matches($0.kind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(InboxFilter.allCases) { option in
                        Button(option.rawValue) { withAnimation(.easeInOut(duration: 0.15)) { filter = option } }
                            .font(.subheadline.weight(filter == option ? .semibold : .regular))
                            .foregroundStyle(filter == option ? Color.white : Color.primary)
                            .padding(.horizontal, 15).frame(minHeight: 44)
                            .accessibilityAddTraits(filter == option ? .isSelected : [])
                            .background(filter == option ? Color.accentColor : Color.secondary.opacity(0.1), in: Capsule())
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            if items.isEmpty {
                ContentUnavailableView {
                    Label(filter == .all ? "Nothing waiting" : "No \(filter.rawValue.lowercased()) yet", systemImage: "tray")
                } description: {
                    Text(engine.devices.isEmpty ? "Connect your Mac to send links, files, and notes to this device." : "Toss something from your Mac, iPhone, or iPad and it’ll appear here.")
                } actions: {
                    if engine.devices.isEmpty {
                        Button("Connect a Device", systemImage: "qrcode.viewfinder") { showScanner = true }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Check for Transfers", systemImage: "arrow.clockwise") { Task { await engine.syncRemote(); await engine.refresh() } }
                    }
                    if filter != .all { Button("Show All") { filter = .all } }
                }
            } else {
                List(items) { item in
                    NavigationLink(value: TossRoute.transfer(item.id)) {
                        TransferRow(item: item, deviceName: engine.devices.first(where: { $0.id == item.senderDeviceID })?.name ?? "Your device",
                                    needsApproval: item.status == .queued)
                    }
                    .swipeActions(edge: .leading) {
                        Button("Read", systemImage: "checkmark") { Task { await engine.markRead(item) } }.tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Later", systemImage: "bookmark") { Task { await engine.archive(item) } }.tint(.blue)
                    }
                }
                .listStyle(.plain)
                .refreshable { await engine.syncRemote(); await engine.refresh() }
            }
        }
        .navigationTitle("Inbox")
        .sheet(isPresented: $showScanner) { PairingScannerView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    NavigationLink(value: TossRoute.later) { Image(systemName: "bookmark") }
                        .accessibilityLabel("Later")
                    NavigationLink(value: TossRoute.history) { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("History")
                }
            }
        }
    }
}

struct LaterView: View {
    @Environment(TossEngine.self) private var engine
    private var items: [TransferItem] {
        engine.transfers.filter { $0.isArchived || ($0.scheduledAt != nil && $0.status == .queued) }
    }
    var body: some View {
        List(items) { item in
            NavigationLink(value: TossRoute.transfer(item.id)) {
                TransferRow(item: item, deviceName: item.scheduledAt?.formatted(date: .abbreviated, time: .shortened) ?? "Saved")
            }
            .swipeActions {
                Button("Remove", systemImage: "trash", role: .destructive) { Task { await engine.delete(item) } }
            }
        }
        .overlay { if items.isEmpty { ContentUnavailableView("Nothing saved", systemImage: "bookmark", description: Text("Save an item for Later from Send or from any transfer. It stays on this device until you need it.")) } }
        .navigationTitle("Later")
    }
}

struct HistoryView: View {
    @Environment(TossEngine.self) private var engine
    @State private var query = ""
    @State private var filter: InboxFilter = .all

    private var results: [TransferItem] {
        engine.transfers.filter { item in
            filter.matches(item.kind) && (query.isEmpty ||
                [item.title, item.subtitle, item.text ?? "", item.sourceURL?.absoluteString ?? "",
                 item.filename ?? "", engine.devices.first(where: { $0.id == item.senderDeviceID })?.name ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        List {
            Picker("Filter", selection: $filter) {
                ForEach(InboxFilter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).listRowSeparator(.hidden)
            ForEach(results) { item in
                NavigationLink(value: TossRoute.transfer(item.id)) {
                    TransferRow(item: item, deviceName: engine.devices.first { $0.id == (item.senderDeviceID == engine.identity.id ? item.receiverDeviceID : item.senderDeviceID) }?.name ?? "This device", outgoing: item.senderDeviceID == engine.identity.id && item.receiverDeviceID != engine.identity.id)
                }
            }
            .onDelete { offsets in
                for index in offsets { Task { await engine.delete(results[index]) } }
            }
        }
        .overlay {
            if results.isEmpty {
                if query.isEmpty { ContentUnavailableView("No transfers yet", systemImage: "clock.arrow.circlepath", description: Text("Your sent and received items will appear here, with their delivery status.")) }
                else { ContentUnavailableView.search(text: query) }
            }
        }
        .searchable(text: $query, prompt: "Search transfers")
        .navigationTitle("History")
    }
}

enum TossRoute: Hashable {
    case later, history, transfer(UUID)
}

struct TossDestination: View {
    @Environment(TossEngine.self) private var engine
    let route: TossRoute
    var body: some View {
        switch route {
        case .later: LaterView()
        case .history: HistoryView()
        case .transfer(let id):
            if let item = engine.transfers.first(where: { $0.id == id }) { TransferDetailView(item: item) }
            else { ContentUnavailableView("Transfer removed", systemImage: "tray", description: Text("This item is no longer in your history.")) }
        }
    }
}
