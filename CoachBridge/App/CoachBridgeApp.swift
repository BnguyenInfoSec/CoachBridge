import GoogleSignIn
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
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
        return true
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
                }
            case .background:
                BackgroundExport.scheduleRefresh()
            default:
                break
            }
        }
    }
}
