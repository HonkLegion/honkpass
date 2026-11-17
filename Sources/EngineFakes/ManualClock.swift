import Foundation
import Synchronization

/// A clock that moves only when a test calls `advance(by:)`.
public final class ManualClock: Clock, Sendable {
    public struct Instant: InstantProtocol {
        var offset: Duration

        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (left: Instant, right: Instant) -> Bool { left.offset < right.offset }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var cancelled: Set<UInt64> = []
        var nextID: UInt64 = 0
        var sleeperWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait([CheckedContinuation<Void, Never>]), done, cancelled }
                let outcome: Outcome = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .cancelled }
                    if deadline <= state.now { return .done }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    let waiters = state.sleeperWaiters
                    state.sleeperWaiters = []
                    return .wait(waiters)
                }
                switch outcome {
                case .wait(let waiters): for waiter in waiters { waiter.resume() }
                case .done: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index)
                }
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the time forward and wakes every sleeper whose deadline has passed.
    public func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Returns when at least one task sleeps on this clock.
    public func waitForSleeper() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hasSleeper = state.withLock { state in
                if state.sleepers.isEmpty {
                    state.sleeperWaiters.append(continuation)
                    return false
                }
                return true
            }
            if hasSleeper { continuation.resume() }
        }
    }
}
