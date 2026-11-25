import Foundation
import EventKit
import UserNotifications
import Combine

/// Upcoming calendar calls are separate from saved recordings. Access is opt-in.
@MainActor
final class MeetingCalendarService: ObservableObject {
    static let shared = MeetingCalendarService()
    static let enabledKey = "voice.calendarMeetingsEnabled"
    static let leadKey = "voice.calendarReminderSeconds"
    private static let notificationPrefix = "voice.calendar.reminder."

    struct UpcomingCall: Identifiable {
        let id: String
        let title: String
        let start: Date
    }

    @Published private(set) var upcoming: [UpcomingCall] = []
    @Published private(set) var status = "Calendar is off"
    @Published private(set) var enabled = false
    private let store = EKEventStore()
    private var reminderGeneration = 0
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if enabled { startMonitoring() }
    }

    /// Called only by the Settings button, never on launch.
    func connect() async {
        do {
            guard try await store.requestFullAccessToEvents() else {
                status = "Calendar access denied. Allow it in System Settings."
                return
            }
            let notifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            enabled = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            startMonitoring()
            if !notifications { status = "Calendar connected. Allow notifications for reminders." }
        } catch {
            status = "Could not connect calendar: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        enabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        upcoming = []
        status = "Calendar is off"
        removeReminders()
    }

    func refresh() {
        guard enabled else { return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            upcoming = []
            status = "Calendar access unavailable. Check System Settings."
            removeReminders()
            return
        }
        let now = Date()
        let end = now.addingTimeInterval(7 * 24 * 60 * 60)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let calls = store.events(matching: predicate).filter { event in
            event.startDate > now && !event.isAllDay && Self.isVideoCall(
                [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
            )
        }.sorted { $0.startDate < $1.startDate }
        upcoming = calls.map { UpcomingCall(id: "\($0.eventIdentifier ?? "event")-\(Int($0.startDate.timeIntervalSince1970))", title: $0.title ?? "Meeting", start: $0.startDate) }
        status = "Calendar connected"
        scheduleReminders()
    }

    static func isVideoCall(_ text: String) -> Bool {
        // Require a real HTTPS link and a recognised meeting host, not a keyword in a title.
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).contains { match in
            guard let url = match.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
            let domains = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]
            return domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    private func startMonitoring() {
        guard timer == nil else { refresh(); return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func removeReminders() {
        reminderGeneration += 1
        let generation = reminderGeneration
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { [weak self] requests in
            Task { @MainActor in
                guard self?.reminderGeneration == generation else { return }
                center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(Self.notificationPrefix) })
            }
        }
    }

    private func scheduleReminders() {
        reminderGeneration += 1
        let generation = reminderGeneration
        let center = UNUserNotificationCenter.current()
        let lead = UserDefaults.standard.object(forKey: Self.leadKey) == nil ? 15 : UserDefaults.standard.integer(forKey: Self.leadKey)
        let calls = Array(upcoming.prefix(50))
        center.getPendingNotificationRequests { [weak self] requests in
            Task { @MainActor in
                guard let self, self.enabled, self.reminderGeneration == generation else { return }
                center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(Self.notificationPrefix) })
                for call in calls {
                    let interval = call.start.timeIntervalSinceNow - Double(lead)
                    guard interval > 0 else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "Meeting soon"
                    content.body = call.title
                    content.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                    center.add(UNNotificationRequest(identifier: Self.notificationPrefix + call.id, content: content, trigger: trigger))
                }
            }
        }
    }
}
