import Dispatch
import Foundation

/// Serializes display writes. Registration delays must run outside this worker.
final class DisplayOperationWorker: @unchecked Sendable {
  static let shared = DisplayOperationWorker()

  private let queue = DispatchQueue(
    label: "dev.narumi.DisplayLoom.display-operations",
    qos: .userInitiated
  )

  init() {}

  func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
    let request = Request()
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          queue.async {
            guard request.start() else {
              continuation.resume(throwing: CancellationError())
              return
            }
            // Once started, return the result even if cancelled. The caller owns
            // any resource created by the operation and must be able to release it.
            continuation.resume(with: Result { try operation() })
          }
        }
      },
      onCancel: {
        request.cancel()
      }
    )
  }

  /// Queues cleanup that must run even when the calling task is cancelled.
  func enqueue(_ operation: @escaping () -> Void) {
    queue.async(execute: DispatchWorkItem(block: operation))
  }

  private final class Request: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }

    func start() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return !cancelled
    }
  }
}
