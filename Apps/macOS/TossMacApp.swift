import AppKit
import Carbon
import SwiftUI
import TossCore
import UserNotifications
import Observation

@main @MainActor
struct TossMacApp: App {
    @NSApplicationDelegateAdaptor(TossMacDelegate.self) private var appDelegate
    @State private var engine: TossEngine? = try? TossEngine()
    @State private var hotKey = HotKeyCenter()
    @State private var route = MacRoute()
    @AppStorage("appearance-v1") private var appearance = "system"

    var body: some Scene {
        WindowGroup("Toss", id: "main") {
            MacRootView(engine: $engine, hotKey: hotKey, appDelegate: appDelegate)
                .environment(route)
                .environment(hotKey)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 950, height: 620)

        Window("Send with Toss", id: "compose") {
            if let engine {
                MacComposerView().environment(engine).environment(route).preferredColorScheme(colorScheme)
            } else { StorageRecoveryView { engine = try? TossEngine() } }
        }
        .defaultSize(width: 580, height: 300)
        .windowResizability(.contentSize)

        MenuBarExtra("Toss", systemImage: "paperplane") {
            if let engine {
                MacMenuView().environment(engine).environment(route)
                    .task {
                        appDelegate.engine = engine
                        NSApp.registerForRemoteNotifications()
                        engine.start()
                    }
            }
            else { StorageRecoveryView { engine = try? TossEngine() } }
        }
        .menuBarExtraStyle(.window)
    }

    private var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }
}

private struct MacRootView: View {
    @Binding var engine: TossEngine?
    let hotKey: HotKeyCenter
    let appDelegate: TossMacDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let engine { MacMainView().environment(engine) }
            else { StorageRecoveryView { engine = try? TossEngine() } }
        }
        .task(id: engine?.identity.id) {
            UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
            appDelegate.engine = engine
            NSApp.registerForRemoteNotifications()
            engine?.start()
            hotKey.register()
            if let current = engine {
                current.onIncoming = { [weak current] item in
                    guard let current else { return }
                    Task { await IncomingNotifier.post(item: item, sender: current.devices.first(where: { $0.id == item.senderDeviceID })) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await engine?.syncRemote() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tossHotKey)) { _ in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "compose")
        }
    }
}

@MainActor
final class TossMacDelegate: NSObject, NSApplicationDelegate {
    weak var engine: TossEngine?

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await engine?.syncRemote() }
    }
}

extension Notification.Name {
    static let tossHotKey = Notification.Name("TossHotKey")
}

@MainActor @Observable
final class HotKeyCenter {
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var currentPreference = ""
    private(set) var usesFallback = false
    private(set) var registrationError: String?

    func register(preference: String = UserDefaults.standard.string(forKey: "shortcut-v1") ?? "automatic") {
        guard hotKeyRef == nil || currentPreference != preference else { return }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        currentPreference = preference
        registrationError = nil
        usesFallback = false
        let types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        if handler == nil {
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { NotificationCenter.default.post(name: .tossHotKey, object: nil) }
                return noErr
            }, 1, types, nil, &handler)
        }
        let identifier = EventHotKeyID(signature: 0x544F5353, id: 1)
        let chosen = preference == "option" ? UInt32(cmdKey | optionKey) : UInt32(cmdKey | shiftKey)
        let primary = RegisterEventHotKey(UInt32(kVK_Space), chosen, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        if primary != noErr && preference == "automatic" {
            usesFallback = true
            let fallback = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | optionKey), identifier,
                                               GetApplicationEventTarget(), 0, &hotKeyRef)
            if fallback != noErr { registrationError = "Both Toss shortcuts are in use. Choose another in system settings." }
        } else if primary != noErr {
            registrationError = "This shortcut is in use by another app. Choose the other Toss shortcut."
        }
    }
}
