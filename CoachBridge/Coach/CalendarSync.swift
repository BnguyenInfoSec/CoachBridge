import EventKit
import UIKit
import os

/// Two-way calendar sync:
/// - reads the athlete's calendars (times + titles) so sessions land in free time and Claude can plan around them;
/// - writes planned sessions into its own "Training" calendar (iCloud when available).
/// It only ever creates, edits or deletes events in that Training calendar — never in your other calendars.
@MainActor
final class CalendarSync: ObservableObject {
    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published var readEnabled: Bool { didSet { defaults.set(readEnabled, forKey: Key.read) } }
    @Published var writeEnabled: Bool { didSet { defaults.set(writeEnabled, forKey: Key.write) } }
    @Published private(set) var busy: [BusyBlock] = []
    /// "yyyy-MM-dd#index" → where that session sits.
    @Published private(set) var scheduled: [String: DateInterval] = [:]
    /// Sessions that didn't fit anywhere that day.
    @Published private(set) var unplaced: Set<String> = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSummary: String?
    @Published var errorText: String?
    @Published private(set) var choices: [String: Bool]

    let store = EKEventStore()
    static let horizonDays = 14
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CoachBridge", category: "calendar")

    private enum Key {
        static let read = "calendar.read"
        static let write = "calendar.write"
        static let trainingID = "calendar.trainingID"
        static let lastWritten = "calendar.lastWritten"
        static let choices = "calendar.choices"
    }

    init() {
        readEnabled = defaults.object(forKey: Key.read) as? Bool ?? true
        writeEnabled = defaults.object(forKey: Key.write) as? Bool ?? true
        choices = defaults.dictionary(forKey: Key.choices) as? [String: Bool] ?? [:]
    }

    var hasAccess: Bool { status == .fullAccess }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            errorText = error.localizedDescription
        }
        status = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: Which calendars to read

    private var trainingID: String? { defaults.string(forKey: Key.trainingID) }

    func readableCalendars() -> [EKCalendar] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event)
            .filter { $0.calendarIdentifier != trainingID }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Birthdays and holiday calendars are off by default; everything else is on.
    func isIncluded(_ c: EKCalendar) -> Bool {
        if let v = choices[c.calendarIdentifier] { return v }
        return !(c.type == .birthday || c.title.localizedCaseInsensitiveContains("holiday"))
    }

    func setIncluded(_ c: EKCalendar, _ on: Bool) {
        choices[c.calendarIdentifier] = on
        defaults.set(choices, forKey: Key.choices)
    }

    // MARK: Reading

    func loadBusy(from start: Date, to end: Date) -> [BusyBlock] {
        guard hasAccess, readEnabled else { return [] }
        let cals = readableCalendars().filter(isIncluded)
        guard !cals.isEmpty else { return [] }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: cals))
        return events
            .filter { $0.isAllDay || $0.availability != .free }
            .map { BusyBlock(start: $0.startDate, end: $0.endDate, title: $0.title, allDay: $0.isAllDay) }
    }

    /// Next `days` of the calendar as text for Claude (times + titles, nothing else).
    func describe(days: Int, from today: Date, calendar: Calendar) -> String? {
        guard hasAccess, readEnabled else { return nil }
        let start = calendar.startOfDay(for: today)
        let list = (0..<days).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        let blocks = loadBusy(from: start, to: calendar.date(byAdding: .day, value: days, to: start)!)
        return Scheduler.describe(blocks, days: list, calendar: calendar)
    }

    // MARK: Sync

    /// Places the next two weeks of sessions and, if enabled, writes them to the Training calendar.
    func sync(plan: PlanModel, weather: WeatherModel) async {
        errorText = nil
        let e = plan.engine
        let cal = e.calendar
        let today = cal.startOfDay(for: .now)
        let end = e.add(today, days: Self.horizonDays)
        busy = loadBusy(from: today, to: end)

        struct Desired { let key: String; let session: PlanSession; let slot: DateInterval?; let day: Date; let allDay: Bool }
        var desired: [Desired] = []
        var placed: [String: DateInterval] = [:]
        var missing: Set<String> = []

        for i in 0..<Self.horizonDays {
            let d = e.add(today, days: i)
            let day = plan.day(d)
            let active = day.sessions.enumerated().filter { $0.element.kind != .rest }
            for (idx, s) in active where s.kind == .snow || s.kind == .fun {
                desired.append(Desired(key: "\(day.iso)#\(idx)", session: s, slot: nil, day: d, allDay: true))
            }
            var dayBusy = busy.filter { $0.start < e.add(d, days: 1) && $0.end > d }

            // The athlete's own sessions keep the exact time they entered, and block that time.
            for (idx, s) in active where s.addedByAthlete && s.kind != .snow && s.kind != .fun {
                guard let start = Scheduler.time(s.startTime, on: d, calendar: cal) else { continue }
                let slot = DateInterval(start: start, duration: TimeInterval(max(15, s.rx?.durationMin ?? 45) * 60))
                let key = "\(day.iso)#\(idx)"
                placed[key] = slot
                desired.append(Desired(key: key, session: s, slot: slot, day: d, allDay: false))
                dayBusy.append(BusyBlock(start: slot.start, end: slot.end, title: s.title, allDay: false))
            }

            let timed = active.filter { !$0.element.addedByAthlete && $0.element.kind != .snow && $0.element.kind != .fun }
            guard !timed.isEmpty else { continue }
            let durations = timed.map { max(15, $0.element.rx?.durationMin ?? 45) }
            let preferred = Scheduler.time(timed.first?.element.startTime, on: d, calendar: cal)
            let slots = Scheduler.place(durations: durations, preferredStart: preferred, day: d,
                                        busy: dayBusy, calendar: cal, hot: weather.isHot(d),
                                        work: plan.profile.work)
            for (j, item) in timed.enumerated() {
                let key = "\(day.iso)#\(item.offset)"
                if let slot = slots[j] { placed[key] = slot } else { missing.insert(key) }
                desired.append(Desired(key: key, session: item.element, slot: slots[j], day: d, allDay: slots[j] == nil))
            }
        }

        if writeEnabled && hasAccess {
            do {
                let written = try write(desired.map { ($0.key, $0.session, $0.slot, $0.day, $0.allDay) },
                                        from: today, to: end, calendar: cal)
                // Respect sessions the athlete moved by hand in Calendar.
                for (k, v) in written { placed[k] = v }
                lastSummary = "\(desired.count) sessions in your Training calendar" + (missing.isEmpty ? "" : " · \(missing.count) without a free slot")
            } catch {
                errorText = "Couldn't update the Training calendar: \(error.localizedDescription)"
                log.error("Calendar write failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            lastSummary = "Times suggested in the app only" + (missing.isEmpty ? "" : " · \(missing.count) without a free slot")
        }
        scheduled = placed
        unplaced = missing
        lastSync = .now
        log.info("Calendar sync: \(desired.count, privacy: .public) sessions, \(missing.count, privacy: .public) unplaced")
    }

    func slot(for day: DayPlan, index: Int) -> DateInterval? { scheduled["\(day.iso)#\(index)"] }
    func isUnplaced(_ day: DayPlan, index: Int) -> Bool { unplaced.contains("\(day.iso)#\(index)") }

    /// Busy blocks on a given day (for the day view).
    func busy(on day: Date, calendar: Calendar = .current) -> [BusyBlock] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return busy.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
    }

    // MARK: Training calendar

    private func trainingCalendar() throws -> EKCalendar {
        if let id = trainingID, let c = store.calendar(withIdentifier: id) { return c }
        let c = EKCalendar(for: .event, eventStore: store)
        c.title = "Training"
        c.cgColor = UIColor(hex: 0x1baf7a).cgColor
        c.source = store.sources.first { $0.sourceType == .calDAV && $0.title == "iCloud" }
            ?? store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .local }
        try store.saveCalendar(c, commit: true)
        defaults.set(c.calendarIdentifier, forKey: Key.trainingID)
        return c
    }

    /// Deletes the Training calendar and every event in it. Other calendars are untouched.
    func removeTrainingCalendar() {
        guard let id = trainingID, let c = store.calendar(withIdentifier: id) else { return }
        do {
            try store.removeCalendar(c, commit: true)
            defaults.removeObject(forKey: Key.trainingID)
            defaults.removeObject(forKey: Key.lastWritten)
            writeEnabled = false
            lastSummary = "Training calendar removed"
        } catch {
            errorText = error.localizedDescription
        }
    }

    static func marker(_ key: String) -> URL {
        let parts = key.split(separator: "#")
        return URL(string: "coachbridge://session/\(parts[0])/\(parts.count > 1 ? parts[1] : "0")")!
    }

    static func key(from url: URL?) -> String? {
        guard let url, url.scheme == "coachbridge", url.host == "session" else { return nil }
        let p = url.pathComponents.filter { $0 != "/" }
        return p.count == 2 ? "\(p[0])#\(p[1])" : nil
    }

    /// Writes the desired events and returns the final interval for each timed key.
    private func write(_ desired: [(String, PlanSession, DateInterval?, Date, Bool)],
                       from start: Date, to end: Date, calendar: Calendar) throws -> [String: DateInterval] {
        let cal = try trainingCalendar()
        let existing = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [cal]))
        var byKey: [String: EKEvent] = [:]
        for ev in existing { if let k = Self.key(from: ev.url) { byKey[k] = ev } }
        var lastWritten = defaults.dictionary(forKey: Key.lastWritten) as? [String: Double] ?? [:]
        var result: [String: DateInterval] = [:]

        for (key, s, slot, day, allDay) in desired {
            let ev = byKey.removeValue(forKey: key) ?? EKEvent(eventStore: store)
            let isNew = ev.calendar == nil
            ev.calendar = cal
            ev.url = Self.marker(key)
            ev.title = Self.title(for: s, placed: slot != nil || s.kind == .snow || s.kind == .fun)
            ev.notes = Self.notes(for: s)
            let minutes = max(15, s.rx?.durationMin ?? 45)
            if allDay {
                ev.isAllDay = true
                ev.startDate = day
                ev.endDate = calendar.date(byAdding: .day, value: 1, to: day)!
            } else if let slot {
                let moved = !isNew && !ev.isAllDay
                    && lastWritten[key].map { abs(ev.startDate.timeIntervalSince1970 - $0) > 60 } == true
                ev.isAllDay = false
                if moved {
                    ev.endDate = ev.startDate.addingTimeInterval(TimeInterval(minutes * 60))
                } else {
                    ev.startDate = slot.start
                    ev.endDate = slot.end
                }
                result[key] = DateInterval(start: ev.startDate, end: ev.endDate)
            }
            try store.save(ev, span: .thisEvent, commit: false)
            lastWritten[key] = ev.startDate.timeIntervalSince1970
        }
        // Sessions no longer in the plan (Claude removed them, settings changed).
        for (k, ev) in byKey {
            try store.remove(ev, span: .thisEvent, commit: false)
            lastWritten[k] = nil
        }
        try store.commit()
        defaults.set(lastWritten, forKey: Key.lastWritten)
        return result
    }

    static func title(for s: PlanSession, placed: Bool) -> String {
        var t = "\(s.kind.label)\(s.indoor == true ? " (indoor)" : ""): \(s.title)"
        if let m = s.rx?.durationMin, m > 0 { t += " (\(Fmt.hours(m)))" }
        if s.kind == .flex { t += " · optional" }
        if !placed { t = "⚠︎ " + t + " · no free slot" }
        return t
    }

    static func notes(for s: PlanSession) -> String {
        var lines: [String] = []
        if !s.detail.isEmpty { lines.append(s.detail) }
        if let rx = s.rx {
            let targets: [(String, String?)] = [("Distance", rx.distance), ("Intensity", rx.intensity), ("Heart rate", rx.heartRate),
                                                ("Power", rx.power), ("Pace", rx.pace)]
            let t = targets.compactMap { k, v in v.map { "\(k): \($0)" } }
            if !t.isEmpty { lines.append(""); lines += t }
            let fuel: [(String, String?)] = [("Before", rx.fuelBefore), ("During", rx.fuelDuring), ("After", rx.fuelAfter)]
            let f = fuel.compactMap { k, v in v.map { "\(k): \($0)" } }
            if !f.isEmpty { lines.append(""); lines.append("FUEL"); lines += f }
            if let n = rx.notes { lines.append(""); lines.append(n) }
        }
        lines.append("")
        lines.append("Planned by Coach Bridge. If you move this event, the app keeps your time; title and notes are rewritten on each sync.")
        return lines.joined(separator: "\n")
    }
}
