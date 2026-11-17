import AppKit
import Engine

/// Screen lock, system sleep and system idle, as macOS shows them.
public struct MacSystemEvents: SystemEventsPort {
    public init() {}

    public func events() -> AsyncStream<SystemEvent> {
        AsyncStream { continuation in
            let distributed = DistributedNotificationCenter.default()
            let workspace = NSWorkspace.shared.notificationCenter
            let observers = Observers(
                screenLock: distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
                    continuation.yield(.screenLocked)
                },
                sleep: workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
                    continuation.yield(.willSleep)
                })
            // The reference looks at the idle time of the system every thirty seconds.
            let idle = Task {
                var watch = IdleWatch()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(IdleWatch.checkInterval))
                    if watch.becameIdle(idleSeconds: Self.secondsSinceLastInput()) { continuation.yield(.systemIdle) }
                }
            }
            continuation.onTermination = { _ in
                idle.cancel()
                DistributedNotificationCenter.default().removeObserver(observers.screenLock)
                NSWorkspace.shared.notificationCenter.removeObserver(observers.sleep)
            }
        }
    }

    /// The seconds since the last key, pointer or other input event of the login session.
    private static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Observer tokens are only handed back to the centres that made them.
    private struct Observers: @unchecked Sendable {
        let screenLock: any NSObjectProtocol
        let sleep: any NSObjectProtocol
    }
}

/// When the system counts as idle: after five minutes without input, as in the reference
/// (apps/desktop/src/main/power-monitor.main.ts). It reports the change to idle once.
struct IdleWatch {
    static let idleAfter: TimeInterval = 5 * 60
    static let checkInterval = 30

    private var isIdle = false

    mutating func becameIdle(idleSeconds: TimeInterval) -> Bool {
        let wasIdle = isIdle
        isIdle = idleSeconds >= Self.idleAfter
        return isIdle && !wasIdle
    }
}
