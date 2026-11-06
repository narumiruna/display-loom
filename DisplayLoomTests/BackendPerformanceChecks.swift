import CoreGraphics
import Dispatch
import Foundation

@testable import DisplayLoom

/// The CLI probe and XCTest wrappers execute these same cases without displays.
enum BackendPerformanceChecks {
  static func run() async throws {
    try await workerSkipsCancelledQueuedOperation()
    try await workerReturnsResultFromCancelledExecutingOperation()
    try await registrationYieldsWorkerToConnectedDisplayResolution()
    try await registrationTimeoutUsesOriginalMonotonicDeadline()
    try await pendingInvalidationCleansUpOnce()
    try await cancellationDuringRegistrationCleansUpOnce()
    try await cancelledQueuedCreationDoesNotCreateHandle()
    try await cancelledExecutingCreationOwnsAndCleansUpLateHandle()
    try await cancelledExecutingInitialModeCleansUpLateResult()
    try await initialModeFailureIsNormalizedAndCleansUpOnce()
    try await invalidationIsSerializedWithModeWriteAndKeepsDisplayID()
    try await unmirroredModeWritesReachHandle()
    try await modeWriteRechecksMirrorStateOnWorker()
    try await releasedConnectionCleansUpOnce()
    try await mirroredInitialModeIsRejectedAndCleansUpOnce()
    print(
      """
      PASS F2: 15 backend/worker checks \
      (registration, deadlines, cancellation, cleanup, mode safety)
      """
    )
  }

  static func workerSkipsCancelledQueuedOperation() async throws {
    let worker = DisplayOperationWorker()
    let gate = BackendWorkerGate()
    worker.enqueue { gate.block() }
    await gate.entered.wait()
    let handle = BackendTestHandle()
    let task = Task {
      try await worker.perform { handle.recordCreation() }
    }
    task.cancel()
    gate.release()
    do {
      try await task.value
      throw Failure("Queued work must report cancellation")
    } catch is CancellationError {}
    try require(handle.creationCount == 0, "Cancelled queued work must not run")
  }

  static func workerReturnsResultFromCancelledExecutingOperation() async throws {
    let worker = DisplayOperationWorker()
    let gate = BackendWorkerGate()
    let task = Task {
      try await worker.perform {
        gate.block()
        return 42
      }
    }
    await gate.entered.wait()
    task.cancel()
    gate.release()
    let value = try await task.value
    try require(value == 42, "Executing work must return its result after cancellation")
  }

  static func registrationYieldsWorkerToConnectedDisplayResolution() async throws {
    let worker = DisplayOperationWorker()
    let connectedHandle = BackendTestHandle(displayID: 101, registered: true)
    let connectedBackend = makeBackend(worker: worker, handle: connectedHandle)
    let connected = try await connect(connectedBackend)
    let clock = BackendRegistrationTestClock()
    let pendingHandle = BackendTestHandle(displayID: 202)
    let pendingBackend = makeBackend(worker: worker, handle: pendingHandle, clock: clock.clock)
    let pendingTask = Task { try await connect(pendingBackend) }
    let firstInterval = await clock.waitForSleep()
    try require(abs(firstInterval - 0.05) < 0.000001, "Registration interval must be 50 ms")
    try require(pendingHandle.modeCount == 0, "A pending handle must not select its mode")

    try await connectedBackend.setResolution(resolution, for: connected)
    try require(connectedHandle.modeCount == 2, "Registration must yield to connected mode writes")
    try require(pendingHandle.modeCount == 0, "Pending registration must remain suspended")
    try require(pendingHandle.invalidationCount == 0, "Pending creation must retain its handle")

    pendingHandle.register()
    clock.advance(by: 0.05)
    let pending = try await pendingTask.value
    try require(pending.displayID == 202 && pending.isValid, "Registered handle must become valid")
    try require(pendingHandle.modeCount == 1, "Initial mode must be selected exactly once")
    connected.invalidate()
    pending.invalidate()
    try await worker.perform {}
    try require(connectedHandle.invalidationCount == 1, "Connected cleanup must run once")
    try require(pendingHandle.invalidationCount == 1, "Registered cleanup must run once")
  }

  static func registrationTimeoutUsesOriginalMonotonicDeadline() async throws {
    let worker = DisplayOperationWorker()
    let handle = BackendTestHandle()
    let clock = BackendRegistrationTestClock()
    let backend = makeBackend(worker: worker, handle: handle, clock: clock.clock)
    let task = Task { try await connect(backend) }
    let firstInterval = await clock.waitForSleep()
    try require(abs(firstInterval - 0.05) < 0.000001, "First probe must wait 50 ms")

    // A delayed probe must not start a fresh two-second timeout.
    clock.advance(by: 1.99)
    let finalInterval = await clock.waitForSleep()
    try require(abs(finalInterval - 0.01) < 0.000001, "Probe delay must respect remaining time")
    handle.register()
    clock.advance(by: 0.02)
    try await requireFailure(task, expected: .registrationTimedOut)
    try await worker.perform {}
    try require(handle.modeCount == 0, "Late registration must not select a mode")
    try require(handle.invalidationCount == 1, "Timeout must clean up exactly once")
  }

  static func pendingInvalidationCleansUpOnce() async throws {
    let worker = DisplayOperationWorker()
    let handle = BackendTestHandle()
    let clock = BackendRegistrationTestClock()
    let backend = makeBackend(worker: worker, handle: handle, clock: clock.clock)
    let task = Task { try await connect(backend) }
    _ = await clock.waitForSleep()
    handle.terminate()
    clock.advance(by: 0.05)
    try await requireFailure(task, expected: .invalidated)
    try await worker.perform {}
    try require(handle.modeCount == 0, "Invalidated pending handle must not select a mode")
    try require(handle.invalidationCount == 1, "Invalidation must clean up exactly once")
  }

  static func cancellationDuringRegistrationCleansUpOnce() async throws {
    let worker = DisplayOperationWorker()
    let handle = BackendTestHandle()
    let clock = BackendRegistrationTestClock()
    let backend = makeBackend(worker: worker, handle: handle, clock: clock.clock)
    let task = Task { try await connect(backend) }
    _ = await clock.waitForSleep()
    task.cancel()
    try await requireCancelled(task)
    try await worker.perform {}

    // A late registration cannot select a mode or regain ownership.
    handle.register()
    clock.advance(by: 2)
    try await worker.perform {}
    try require(handle.modeCount == 0, "Registration after cancellation must not select a mode")
    try require(handle.invalidationCount == 1, "Cancellation must clean up exactly once")
  }

  static func cancelledQueuedCreationDoesNotCreateHandle() async throws {
    let worker = DisplayOperationWorker()
    let gate = BackendWorkerGate()
    worker.enqueue { gate.block() }
    await gate.entered.wait()
    let handle = BackendTestHandle(registered: true)
    let backend = makeBackend(worker: worker, handle: handle)
    let task = Task { try await connect(backend) }
    task.cancel()
    gate.release()
    try await requireCancelled(task)
    try await worker.perform {}
    try require(handle.creationCount == 0, "Cancelled queued creation must not allocate")
    try require(handle.invalidationCount == 0, "Unallocated handles need no cleanup")
  }

  static func cancelledExecutingCreationOwnsAndCleansUpLateHandle() async throws {
    let worker = DisplayOperationWorker()
    let gate = BackendWorkerGate()
    let handle = BackendTestHandle(registered: true)
    let backend = CoreGraphicsVirtualDisplayBackend(
      worker: worker,
      isAPIAvailable: { true },
      makeHandle: { _, _, _ in
        handle.recordCreation()
        gate.block()
        return handle
      },
      isInMirrorSet: { _ in false }
    )
    let task = Task { try await connect(backend) }
    await gate.entered.wait()
    task.cancel()
    gate.release()
    try await requireCancelled(task)
    try await worker.perform {}
    try require(handle.creationCount == 1, "Executing creation must finish")
    try require(handle.modeCount == 0, "Cancelled creation must not select its initial mode")
    try require(handle.invalidationCount == 1, "Late creation result must be cleaned up once")
  }

  static func cancelledExecutingInitialModeCleansUpLateResult() async throws {
    let worker = DisplayOperationWorker()
    let gate = BackendWorkerGate()
    let handle = BackendTestHandle(registered: true)
    handle.onSetMode = { gate.block() }
    let backend = makeBackend(worker: worker, handle: handle)
    let task = Task { try await connect(backend) }
    await gate.entered.wait()
    task.cancel()
    gate.release()
    try await requireCancelled(task)
    try await worker.perform {}
    try require(handle.modeCount == 1, "Executing initial mode must finish")
    try require(handle.invalidationCount == 1, "Late initial mode result must be cleaned up once")
  }

  static func initialModeFailureIsNormalizedAndCleansUpOnce() async throws {
    let worker = DisplayOperationWorker()
    let handle = BackendTestHandle(registered: true)
    handle.onSetMode = {
      throw NSError(
        domain: VSCGVirtualDisplayErrorDomain,
        code: VSCGVirtualDisplayError.Code.modeUnavailable.rawValue
      )
    }
    let backend = makeBackend(worker: worker, handle: handle)
    let task = Task { try await connect(backend) }
    try await requireFailure(task, expected: .modeUnavailable)
    try await worker.perform {}
    try require(handle.modeCount == 1, "Initial mode must not retry after an error")
    try require(handle.invalidationCount == 1, "Initial mode failure must clean up once")
  }

  static func invalidationIsSerializedWithModeWriteAndKeepsDisplayID() async throws {
    let worker = DisplayOperationWorker()
    let handle = BackendTestHandle(registered: true)
    let backend = makeBackend(worker: worker, handle: handle)
    let connection = try await connect(backend)
    let gate = BackendWorkerGate()
    handle.onSetMode = { gate.block() }
    let task = Task { try await backend.setResolution(resolution, for: connection) }
    await gate.entered.wait()
    // Both status reads must remain available while the worker is blocked.
    let validDuringMode = await MainActor.run { connection.isValid }
    connection.invalidate()
    connection.invalidate()
    let validOnMain = await MainActor.run { connection.isValid }
    let invalidationsDuringMode = handle.invalidationCount
    gate.release()
    try await task.value
    try await worker.perform {}
    try require(validDuringMode, "MainActor must read handle validity during a mode write")
    try require(!validOnMain, "Invalidation must be visible on MainActor without blocking")
    try require(invalidationsDuringMode == 0, "Handle invalidation must not overlap a mode write")
    try require(handle.invalidationCount == 1, "Repeated invalidation must run once")
    try require(connection.displayID == 123, "Display ID must remain stable after invalidation")
    do {
      try await backend.setResolution(resolution, for: connection)
      throw Failure("Invalidated connection must reject mode writes")
    } catch let error as VirtualDisplayBackendError {
      try require(error == .invalidated, "Invalidated mode error must be normalized")
    }
    try require(handle.modeCount == 2, "Invalidated mode write must not reach the handle")
  }

  static func unmirroredModeWritesReachHandle() async throws {
    let worker = DisplayOperationWorker()
    let handle = BackendTestHandle(registered: true)
    let backend = makeBackend(worker: worker, handle: handle)
    let connection = try await connect(backend)
    try await backend.setResolution(resolution, for: connection)
    try require(handle.modeCount == 2, "Unmirrored initial and later modes must reach the handle")
    connection.invalidate()
    try await worker.perform {}
  }

  static func modeWriteRechecksMirrorStateOnWorker() async throws {
    for mirrorState in [BackendTestHandle.MirrorState.secondary, .primary] {
      let worker = DisplayOperationWorker()
      let handle = BackendTestHandle(registered: true)
      let backend = makeBackend(worker: worker, handle: handle)
      let connection = try await connect(backend)
      let gate = BackendWorkerGate()
      worker.enqueue {
        gate.block()
        handle.mirrorState = mirrorState
      }
      await gate.entered.wait()
      let stateBeforeWrite = handle.mirrorState
      let task = Task { try await backend.setResolution(resolution, for: connection) }
      gate.release()
      do {
        try await task.value
        throw Failure("A queued mirror \(mirrorState) must reject the mode")
      } catch let error as VirtualDisplayBackendError {
        try require(error == .invalidConfiguration, "Mirrored mode error must be normalized")
      }
      try require(stateBeforeWrite == .unmirrored, "Target must start unmirrored")
      try require(handle.modeCount == 1, "Worker recheck must reject a mirror \(mirrorState)")
      connection.invalidate()
      try await worker.perform {}
    }
  }

  static func releasedConnectionCleansUpOnce() async throws {
    let worker = DisplayOperationWorker()
    let handle = BackendTestHandle(registered: true)
    let backend = makeBackend(worker: worker, handle: handle)
    var connection: (any VirtualDisplayConnection)? = try await connect(backend)
    let released = WeakConnection(connection!)
    connection = nil
    try await worker.perform {}
    try require(released.value == nil, "The backend must not retain a released connection")
    try require(handle.invalidationCount == 1, "Released connection must clean up once")
  }

  static func mirroredInitialModeIsRejectedAndCleansUpOnce() async throws {
    for mirrorState in [BackendTestHandle.MirrorState.secondary, .primary] {
      let worker = DisplayOperationWorker()
      let handle = BackendTestHandle(registered: true)
      handle.mirrorState = mirrorState
      let backend = makeBackend(worker: worker, handle: handle)
      let task = Task { try await connect(backend) }
      try await requireFailure(task, expected: .invalidConfiguration)
      try await worker.perform {}
      try require(handle.modeCount == 0, "Initial mode must reject a mirror \(mirrorState)")
      try require(handle.invalidationCount == 1, "Rejected initial mode must clean up once")
    }
  }

  private static var resolution: ResolutionPreset {
    ResolutionPreset.preset(withID: "1920x1080")!
  }

  private static func makeBackend(
    worker: DisplayOperationWorker,
    handle: BackendTestHandle,
    clock: DisplayRegistrationClock = .continuous
  ) -> CoreGraphicsVirtualDisplayBackend {
    CoreGraphicsVirtualDisplayBackend(
      worker: worker,
      isAPIAvailable: { true },
      makeHandle: { _, _, _ in
        handle.recordCreation()
        return handle
      },
      registrationClock: clock,
      isInMirrorSet: { _ in handle.mirrorState != .unmirrored }
    )
  }

  private static func connect(_ backend: CoreGraphicsVirtualDisplayBackend) async throws
    -> any VirtualDisplayConnection
  {
    try await backend.connect(
      profile: VirtualDisplayProfile(name: "Backend Test", resolutionID: resolution.id),
      resolution: resolution,
      terminationHandler: {}
    )
  }

  private static func requireFailure(
    _ task: Task<any VirtualDisplayConnection, Error>,
    expected: VirtualDisplayBackendError
  ) async throws {
    do {
      _ = try await task.value
      throw Failure("Expected connection failure: \(expected)")
    } catch let error as VirtualDisplayBackendError {
      try require(error == expected, "Unexpected connection error: \(error), expected \(expected)")
    }
  }

  private static func requireCancelled(
    _ task: Task<any VirtualDisplayConnection, Error>
  ) async throws {
    do {
      _ = try await task.value
      throw Failure("Expected connection cancellation")
    } catch is CancellationError {}
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message) }
  }

  private final class WeakConnection {
    weak var value: (any VirtualDisplayConnection)?
    init(_ value: any VirtualDisplayConnection) { self.value = value }
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}

/// A one-shot event that does not occupy an executor while waiting.
final class BackendTestEvent: @unchecked Sendable {
  private let lock = NSLock()
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if signalled {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func signal() {
    lock.lock()
    signalled = true
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in pending { waiter.resume() }
  }
}

/// Blocks only the serial worker, never the test's async executor.
final class BackendWorkerGate: @unchecked Sendable {
  let entered = BackendTestEvent()
  private let semaphore = DispatchSemaphore(value: 0)

  func block() {
    entered.signal()
    semaphore.wait()
  }

  func release() {
    semaphore.signal()
  }
}

final class BackendTestHandle: CoreGraphicsVirtualDisplayHandling, @unchecked Sendable {
  enum MirrorState {
    case unmirrored, secondary, primary
  }

  let displayID: CGDirectDisplayID
  private let lock = NSLock()
  private var registered = false
  private var invalidated = false
  private var creations = 0
  private var invalidations = 0
  private var modes = 0
  private var mirroring = MirrorState.unmirrored
  // Set hooks before the operation starts; do not change them while it runs.
  var onSetMode: (() throws -> Void)?
  var onInvalidate: (() -> Void)?

  init(displayID: CGDirectDisplayID = 123, registered: Bool = false) {
    self.displayID = displayID
    self.registered = registered
  }

  var isValid: Bool {
    lock.lock()
    defer { lock.unlock() }
    return registered && !invalidated
  }

  var isInvalidated: Bool {
    lock.lock()
    defer { lock.unlock() }
    return invalidated
  }

  var creationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return creations
  }

  var invalidationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return invalidations
  }

  var modeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return modes
  }

  var mirrorState: MirrorState {
    get {
      lock.lock()
      defer { lock.unlock() }
      return mirroring
    }
    set {
      lock.lock()
      mirroring = newValue
      lock.unlock()
    }
  }

  func recordCreation() {
    lock.lock()
    creations += 1
    lock.unlock()
  }

  func register() {
    lock.lock()
    registered = true
    lock.unlock()
  }

  func terminate() {
    lock.lock()
    invalidated = true
    lock.unlock()
  }

  func setMode(width: UInt32, height: UInt32, refreshRate: Double) throws {
    lock.lock()
    modes += 1
    lock.unlock()
    try onSetMode?()
  }

  func invalidate() {
    lock.lock()
    invalidated = true
    invalidations += 1
    lock.unlock()
    onInvalidate?()
  }
}

/// Each delay stays suspended until advance() or task cancellation.
final class BackendRegistrationTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval = 0
  private var cancelled = false
  private var sleeper: CheckedContinuation<Void, Error>?
  private var interval: TimeInterval?
  private var observers: [CheckedContinuation<TimeInterval, Never>] = []

  var clock: DisplayRegistrationClock {
    DisplayRegistrationClock(now: { self.now }, sleep: { try await self.sleep($0) })
  }

  private var now: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return time
  }

  func waitForSleep() async -> TimeInterval {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let interval {
        lock.unlock()
        continuation.resume(returning: interval)
      } else {
        observers.append(continuation)
        lock.unlock()
      }
    }
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    time += seconds
    let pending = sleeper
    sleeper = nil
    interval = nil
    lock.unlock()
    pending?.resume()
  }

  private func sleep(_ seconds: TimeInterval) async throws {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
          lock.lock()
          if cancelled {
            lock.unlock()
            pending.resume(throwing: CancellationError())
            return
          }
          precondition(sleeper == nil)
          sleeper = pending
          interval = seconds
          let pendingObservers = observers
          observers.removeAll()
          lock.unlock()
          for observer in pendingObservers { observer.resume(returning: seconds) }
        }
      },
      onCancel: {
        self.cancelSleep()
      }
    )
  }

  private func cancelSleep() {
    lock.lock()
    cancelled = true
    let pending = sleeper
    sleeper = nil
    interval = nil
    lock.unlock()
    pending?.resume(throwing: CancellationError())
  }
}
