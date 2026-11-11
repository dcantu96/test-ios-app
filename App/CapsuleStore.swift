import Foundation
import Observation

enum SealDuration: Int, CaseIterable, Identifiable {
    case tenSeconds = 10
    case minute = 60
    case hour = 3_600
    case day = 86_400
    case year = 31_536_000

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .tenSeconds: "10s"
        case .minute: "1m"
        case .hour: "1h"
        case .day: "1d"
        case .year: "1y"
        }
    }
}

@MainActor
@Observable
final class CapsuleStore {
    var capsules: [Capsule] = []
    var errorMessage: String?
    var lockedNotice: String?
    var revealed: Capsule?

    /// Server clock minus device clock, so countdowns match the server, which is the one that decides.
    private(set) var clockOffset: TimeInterval = 0
    private let api: CapsuleAPI

    init(api: CapsuleAPI = .live) {
        self.api = api
    }

    func refresh() async {
        do {
            let list = try await api.list()
            capsules = list
            if let first = list.first { syncClock(first) }
            errorMessage = nil
        } catch {
            errorMessage = "Can't reach the capsule vault at \(api.baseURL.absoluteString)."
        }
    }

    func seal(_ message: String, for duration: SealDuration) async -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        do {
            let capsule = try await api.seal(message: text, seconds: duration.rawValue)
            syncClock(capsule)
            capsules.insert(capsule, at: 0)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func open(_ capsule: Capsule) async {
        do {
            switch try await api.open(id: capsule.id) {
            case .opened(let opened):
                replace(opened)
                revealed = opened
            case .stillSealed(let sealed):
                syncClock(sealed)
                replace(sealed) // the server counted this knock
                let notice = "Knock #\(sealed.knocks). Still sealed: \(Self.countdown(TimeInterval(sealed.secondsRemaining))) to go."
                lockedNotice = notice
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if lockedNotice == notice { lockedNotice = nil }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remaining(for capsule: Capsule, at date: Date) -> TimeInterval {
        capsule.unlocksAt.timeIntervalSince(date.addingTimeInterval(clockOffset))
    }

    private func syncClock(_ capsule: Capsule) {
        clockOffset = capsule.serverNow.timeIntervalSinceNow
    }

    private func replace(_ capsule: Capsule) {
        if let index = capsules.firstIndex(where: { $0.id == capsule.id }) {
            capsules[index] = capsule
        }
    }

    nonisolated static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        let days = s / 86_400, hours = (s % 86_400) / 3_600, minutes = (s % 3_600) / 60, secs = s % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return String(format: "%d:%02d", minutes, secs) }
        return "\(secs)s"
    }
}
