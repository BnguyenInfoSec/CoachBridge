import Foundation
import WidgetKit

/// Keeps the iPhone widget current: today's sessions and the go / no-go word, written to the App
/// Group whenever the plan or recovery changes. No health numbers — see `PhoneGlance`.
@MainActor
enum PhoneGlancePublisher {
    static func glance(plan: PlanModel, recovery: RecoverySignal.Level?, isDemo: Bool, now: Date) -> PhoneGlance {
        let e = plan.engine
        let day = plan.day(now)
        let training = day.sessions.filter { $0.kind != .rest }
        return PhoneGlance(
            generatedAt: now, dayISO: day.iso, isDemo: isDemo,
            verdict: GoNoGo.decide(recovery: recovery, today: plan.needsSetup ? [] : day.sessions).rawValue,
            sessions: plan.needsSetup ? [] : training.map { s in
                PhoneGlance.Session(title: s.title, symbol: s.kind.symbol, kind: s.kind.rawValue,
                                    start: Scheduler.time(s.startTime, on: day.date, calendar: e.calendar),
                                    minutes: s.rx?.durationMin,
                                    intensity: s.rx?.intensity.map { String($0.split(separator: "—").first ?? Substring($0)).trimmingCharacters(in: .whitespaces) })
            },
            phaseLabel: plan.needsSetup ? nil : e.phaseWeek(now)?.label)
    }

    static func publish() {
        let s = AppServices.shared
        let g = glance(plan: s.plan, recovery: s.dashboard.data?.recovery.level, isDemo: DemoData.isOn, now: .now)
        guard g != PhoneGlanceStore.read() else { return }          // don't spend widget reloads on no change
        PhoneGlanceStore.write(g)
        WidgetCenter.shared.reloadTimelines(ofKind: PhoneGlanceStore.widgetKind)
    }

    static func clear() {
        PhoneGlanceStore.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: PhoneGlanceStore.widgetKind)
    }
}
