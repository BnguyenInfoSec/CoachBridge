import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Both must happen before launch finishes, including background launches.
        MainActor.assumeIsolated {
            BackgroundExport.registerRefreshTask()
            BackgroundExport.startObservers(store: AppServices.shared.health.store)
            BackgroundExport.scheduleRefresh()
            // Before launch finishes too: a feel answered on the watch can be what woke the app.
            AppServices.shared.watchLink.activate()
        }
        // Set before launch finishes, or a tap that launched the app is never delivered.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Tapping "How did your run feel?" opens the sheet for that workout.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["workoutID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await AppServices.shared.prompter.open(workoutID: id)
    }

    /// With the app open, the sheet asks instead; a banner on top of it would ask twice.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix("feel.") ? [] : [.banner, .sound]
    }
}

@main
struct CoachBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var health = AppServices.shared.health
    @StateObject private var google = AppServices.shared.google
    @StateObject private var exporter = AppServices.shared.exporter
    @StateObject private var dashboard = AppServices.shared.dashboard
    @StateObject private var chat = AppServices.shared.chat
    @StateObject private var plan = AppServices.shared.plan
    @StateObject private var calendarSync = AppServices.shared.calendar
    @StateObject private var weather = AppServices.shared.weather
    @StateObject private var watch = AppServices.shared.watch
    @StateObject private var venues = AppServices.shared.venues
    @StateObject private var review = AppServices.shared.review
    @StateObject private var prompter = AppServices.shared.prompter
    @State private var fitMessage: String?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(health)
                .environmentObject(google)
                .environmentObject(exporter)
                .environmentObject(dashboard)
                .environmentObject(chat)
                .environmentObject(plan)
                .environmentObject(calendarSync)
                .environmentObject(weather)
                .environmentObject(watch)
                .environmentObject(venues)
                .environmentObject(review)
                .environmentObject(prompter)
                .onOpenURL { url in
                    // A FIT file opened from Files or shared from a bike computer's app.
                    if url.isFileURL, url.pathExtension.lowercased() == "fit" {
                        Task { fitMessage = await AppServices.shared.importFIT([url]) }
                    } else {
                        _ = GIDSignIn.sharedInstance.handle(url)
                    }
                }
                .alert("FIT import", isPresented: Binding(get: { fitMessage != nil }, set: { if !$0 { fitMessage = nil } })) {
                    Button("OK") { fitMessage = nil }
                } message: {
                    Text(fitMessage ?? "")
                }
                .task { await google.restore() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await exporter.runAutomatic(trigger: .appOpen) }
                Task {
                    await dashboard.ensureLoaded()
                    AppServices.shared.watchLink.push()
                    // Coming back to the app is when a just-finished workout gets asked about.
                    prompter.offerOnOpen()
                    await prompter.workoutsChanged()
                }
            case .background:
                BackgroundExport.scheduleRefresh()
            default:
                break
            }
        }
    }
}
