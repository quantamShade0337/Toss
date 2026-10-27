import SwiftUI
import TossCore
import UserNotifications

@main
struct TossiOSApp: App {
    @UIApplicationDelegateAdaptor(TossMobileDelegate.self) private var appDelegate
    @State private var engine: TossEngine?
    @State private var setupError: String?
    @State private var startupAttempt = 0
    @AppStorage("onboarded-v1") private var onboarded = false
    @AppStorage("appearance-v1") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-reset-onboarding") {
            UserDefaults.standard.removeObject(forKey: "onboarded-v1")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if engine != nil {
                    if onboarded { MainTabs() }
                    else { OnboardingView(onboarded: $onboarded) }
                } else if setupError != nil {
                    StorageRecoveryView { setupError = nil; startupAttempt += 1 }
                } else { ProgressView("Starting Toss…") }
            }
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .environmentIfPresent(engine)
            .task(id: startupAttempt) {
                guard engine == nil else { return }
                do {
                    #if DEBUG
                    if let fixture = try await UITestFixtures.makeEngine() {
                        engine = fixture
                        if !ProcessInfo.processInfo.arguments.contains("--uitest-reset-onboarding") { onboarded = true }
                        return
                    }
                    #endif
                    let created = try TossEngine()
                    engine = created
                    UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
                    created.start()
                    appDelegate.engine = created
                    UIApplication.shared.registerForRemoteNotifications()
                    created.onIncoming = { [weak created] item in
                        guard let created else { return }
                        Task { await IncomingNotifier.post(item: item, sender: created.devices.first(where: { $0.id == item.senderDeviceID })) }
                    }
                } catch { setupError = DeliveryIssue(error: error).guidance }
            }
            .onChange(of: scenePhase) { _, phase in
                #if DEBUG
                if UITestFixtures.isEnabled { return }
                #endif
                if phase == .active {
                    engine?.start()
                    Task { await engine?.syncRemote() }
                }
                else if phase == .background { engine?.stop() }
            }
        }
    }
}

final class TossMobileDelegate: NSObject, UIApplicationDelegate {
    weak var engine: TossEngine?
    private var backgroundEngine: TossEngine?

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            let active = engine ?? (try? TossEngine())
            backgroundEngine = active
            await active?.syncRemote()
            backgroundEngine = nil
            completionHandler(active == nil ? .failed : .newData)
        }
    }
}

private extension View {
    @ViewBuilder func environmentIfPresent(_ engine: TossEngine?) -> some View {
        if let engine { environment(engine) } else { self }
    }
}
