import Foundation

public struct TimeoutError: Error, LocalizedError {
	public let seconds: TimeInterval

	public var errorDescription: String? {
		"The operation timed out after \(Int(seconds))s."
	}
}

/// Runs `operation`, cancelling it and throwing `TimeoutError` if it outlives
/// `seconds`.
///
/// The operation must be cancellable for this to work: a task group waits for
/// all of its children before returning, so a child that ignores cancellation
/// hangs the timeout along with everything else. Anything built on
/// Network.framework callbacks therefore needs `withTaskCancellationHandler`
/// to tear the connection down and resume its continuation.
public func withTimeout<T: Sendable>(
	seconds: TimeInterval,
	operation: @escaping @Sendable () async throws -> T
) async throws -> T {
	try await withThrowingTaskGroup(of: T.self) { group in
		group.addTask { try await operation() }
		group.addTask {
			try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			throw TimeoutError(seconds: seconds)
		}
		guard let result = try await group.next() else {
			throw TimeoutError(seconds: seconds)
		}
		group.cancelAll()
		return result
	}
}
