import Foundation

/// How a limit is being used against the time that has passed: where it would be if it were used
/// evenly until it resets (`expected`), and how far the real use is from that. Shown for the long
/// windows (week, month); the 5 hours are used in bursts, so they keep the forecast instead.
struct Pace: Equatable {
    enum State: Equatable { case onTrack, ahead, behind }

    /// The share of the window that has passed, 0 to 1.
    let expected: Double
    /// The use minus the expected use, in percentage points.
    let difference: Double

    /// Points either way that still count as on track.
    static let tolerance = 5.0
    /// Too early in the window, a few points are most of the use: no pace until a tenth has passed.
    static let minimumElapsed = 0.10

    var state: State {
        abs(difference) < Self.tolerance ? .onTrack : difference > 0 ? .ahead : .behind
    }

    /// "On track", "12% ahead", "12% to spare".
    var text: String {
        let points = Int(abs(difference).rounded())
        switch state {
        case .onTrack: return L("On track")
        case .ahead: return L("%d%% ahead", points)
        case .behind: return L("%d%% to spare", points)
        }
    }

    /// Nil without a known length and reset, before a tenth of the window has passed, once it has
    /// reset, or when it's used up (the panel says so already).
    static func of(_ window: UsageWindow, now: Date) -> Pace? {
        guard let resetsAt = window.resetsAt, resetsAt > now, let minutes = window.windowMinutes, minutes > 0 else { return nil }
        let length = TimeInterval(minutes) * 60
        let elapsed = min(max(now.timeIntervalSince(resetsAt.addingTimeInterval(-length)) / length, 0), 1)
        let used = window.effectivePercent(at: now)
        guard elapsed >= minimumElapsed, used < UsageWindow.exhausted else { return nil }
        return Pace(expected: elapsed, difference: used - elapsed * 100)
    }
}
