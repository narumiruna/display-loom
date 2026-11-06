# Display performance plan

## Goal

Reduce repeated display-update work and keep display configuration waits off the main thread. Preserve connection recovery, mirror intent, error reporting, and saved settings.

This plan covers three performance findings. Implementation is not part of the plan PR.

## Context

Baseline: `a7d259d` on `main`. Source line references and probe results below apply to this revision.

- **F1: Repeated screen updates.** `DisplayLoom/Store/VirtualDisplayStore.swift:451-478` creates a task for each screen-change notification and publishes source and mirror state without an equality check. A Swift CLI probe using the production store and test doubles produced these results with four connected profiles and unchanged state:
  - 100 notifications caused 100 source scans, 400 mirror attempts, and 1,000 `objectWillChange` notifications. These are publisher events, not measured SwiftUI renders.
  - A separate simulated failure probe reached 20 attempts before the probe stopped it. The two-pass limit at line 497 does not bound retries triggered by queued notifications.
- **F2: Shared worker blocked by registration.** `DisplayLoom/Bridge/VSCGVirtualDisplayBridge.m:340-350` performs up to 40 sleeps of 50 ms. Creation and resolution changes share the serial queue in `DisplayLoom/Services/CoreGraphicsVirtualDisplayBackend.swift:33-34`. A registration timeout therefore delays later operations by approximately two seconds, plus API and scheduling time.
- **F3: Main-thread configuration risk.** `DisplayLoom/Services/DisplayMirroringManager.swift:77,127-170` runs the complete mirror transaction on `@MainActor`. A slow `CGCompleteDisplayConfiguration` can block the menu. Actual CoreGraphics latency has not been measured.

The current host has Command Line Tools and a working Swift compiler, but no full Xcode installation. `just test` fails because `/Applications/Xcode.app/Contents/Developer` is absent. The probes did not create or reconfigure a real display. Preserve their cases as repository tests; do not depend on temporary probe files.

Implementation evidence (2026-11-06):

- `just test-performance` passes 27 shared check functions against production sources and the real bridge: 14 backend/worker checks and 13 store/service groups. Three consecutive complete runs passed. The F1 result is one scan, zero restore calls, and zero publications for the original 100-event/four-profile case.
- Native arm64 compilation and Intel x86_64 type-checking/syntax checks pass for macOS 14 with warnings treated as errors. Test-source parsing and Xcode project validation pass; existing project settings and IDs are unchanged.
- All applicable pre-commit hooks pass with the available Command Line Tools toolchain supplied through `TOOLCHAIN_DIR` and its `usr/bin` on `PATH`. Full Xcode commands still fail for the documented missing developer directory; they are external checks, not passed gates.
- Source reviews covered correctness, security, lifecycle, compatibility, regressions, and scope. Review fixes now have gated checks for reconnect cleanup, superseded creation, in-flight recovery budgets, attempted-state snapshots, and successive mode success/failure ordering. No material source-review findings remain.
- Unresolved full-Xcode and live-display items, responsible roles, and release restrictions are retained in `docs/RELEASING.md` under Performance change validation.

## Architecture

- Keep `VirtualDisplayStore`, `NSScreen` access, and published state on `MainActor`.
- Use a shared serial worker for CoreGraphics configuration writes in the backend and mirroring service. Keep each begin/configure/complete transaction in one worker operation. Do not dispatch synchronous work back to the main thread or use concurrent writes to bypass serialization.
- Separate handle creation, registration waiting, and initial mode selection. Retain pending handles until success or cleanup. Schedule registration probes without sleeping on the worker.
- Make mirror writes asynchronous. After each suspension, validate the profile ID, connection token, and current request before changing state. Do not retain a profile array index across a suspension. Reject resolution changes while a mirror change is pending, and recheck actual mirror state on the worker immediately before a mode write.
- Use one store-owned screen-update task. Merge notifications before a pass starts; record one pending update while a pass runs. Publish snapshots only when values differ. Scheduled tasks must not retain the store across a suspended worker operation; retain operation inputs separately and apply results through a weak store reference.
- Identify a failed restore by its connection token, target display ID, requested source UUID, online display ID/UUID set, and observed mirror-source mapping for connected targets. Allow at most one automatic failed attempt for an unchanged snapshot. Distinguish notification updates from explicit selection and wake recovery, which permit another attempt. A changed snapshot also permits an attempt. Do not reset suppression because another notification arrived or add a periodic retry loop.

## Non-Goals

- Change resolution presets, refresh rates, the persistence format, login behavior, or localization.
- Add user settings, environment variables, generic scheduling frameworks, or an unrelated cancellation refactor.
- Claim a GPU, memory, or UI-latency improvement from test-double results alone.

## Plan

Complete these tasks in order. Use controlled gates, fake clocks, and injected operations for deterministic checks; do not use real display changes in default tests.

- [x] Establish regression fixtures for F1-F3 in `DisplayLoomTests/TestDoubles.swift` and the store, coordination, backend, and mirroring test files. Reproduce the notification counts and delayed operations before changing production behavior.
  - Evidence: isolated Swift CLI probes execute the same cases against production sources and reproduce the F1 baseline. Worker gates reproduce queued-operation blocking without a real display. Document the internal worker and handle ownership before changing asynchronous behavior; check available SDK threading constraints and record unsupported-platform questions in the handoff.

- [x] Remove blocking registration polling from the bridge/backend path and use the serial worker for handle writes. Create the handle, schedule each registration check, and set the initial mode only after registration.
  - Preserve the current two-second deadline and 50 ms probe interval. Use a monotonic deadline rather than extending the deadline after each scheduled check.
  - Serialize invalidation with mode writes. Clean up failed, cancelled, or superseded creations, and complete each request exactly once.
  - Evidence: a gated pending registration does not prevent another connected display's resolution operation from completing. Deterministic checks cover registration success, timeout, invalidation, cancellation, and late completion. No registration loop sleeps on an occupied worker.

- [x] Move mirror transactions to the serial worker and propagate `async throws` through `DisplayMirroringManaging`, `VirtualDisplayStore`, menu actions, cleanup paths, and affected tests.
  - Preserve successful-selection persistence and actual-state reporting after failure. Coordinate explicit selection, automatic restoration, resolution changes, disconnect, removal, rename, and termination without overlapping writes to the same target.
  - Evidence: a gated mirror transaction leaves the main actor available to another task. Late results cannot restore a removed connection, overwrite a newer source choice, or access an obsolete profile index. Gated mirror/resolution overlap tests prove that pending mirroring rejects resolution changes and worker-side revalidation prevents a mirrored target's mode write. Existing mirror coordination cases retain their behavior except for the explicit retry distinction in the next task.

- [x] Merge screen notifications and publish only changed snapshots in `VirtualDisplayStore`. Check actual mirror state before a restore write and suppress retries for an unchanged failed restore as defined above.
  - Preserve the final screen state when notifications arrive during a suspended restore. Cancel pending scheduled updates when the store is released. Update `testRestoreFailureExposesActualStateAndClearsAfterRetry` to retry through explicit selection of the saved source; an unchanged notification must no longer reset the failure budget.
  - Evidence: after initial state settles, 100 queued notifications with four unchanged profiles cause one source scan, no restore calls to `setMirror`, and no `objectWillChange` notifications. Events during a pass merge into one pending update; a later relevant state change is not lost. A failed restore that emits queued notifications makes only one automatic attempt for that unchanged snapshot; explicit retry, wake recovery, and source reconnection still work. Weak-reference checks prove store release both before a scheduled pass and during a gated worker operation, with no later publication or follow-up pass.

- [x] Validate the combined changes with isolated Swift CLI probes and compile the changed Swift and Objective-C paths with Command Line Tools. Prepare the external test handoff with exact commands, baseline/updated counts, and known limits.
  - Evidence: deterministic checks for F1-F3 pass without creating a display; error mapping, saved intent, stale-result rejection, and cleanup checks pass. Record the commands and distinguish executed probes from unexecuted XCTest cases. Keep change-caused failures and unresolved ownership questions blocking.

## Completion Checklist

- [x] F1 regression evidence shows merged updates, no unchanged-state publications, and bounded failure feedback without losing later valid updates.
- [x] F2 regression evidence shows that registration waits yield the worker and preserve deadlines, cleanup, and error mapping.
- [x] F3 regression evidence shows that mirror transactions yield the main actor and cannot apply stale results to store state.
- [x] Available compilation and deterministic checks pass, and the diff contains no unrelated behavior or persistence changes.
- [x] External handoff instructions and restrictions are recorded. Before deleting this completed plan, move unresolved handoff items to `docs/RELEASING.md`. Plan completion alone does not establish release readiness.

## External Handoff

1. **Full app build and XCTest suite**
   - Responsible role: maintainer with a macOS build host.
   - Prerequisite: full Xcode with the developer directory expected by `justfile`, or an explicit `DEVELOPER_DIR` override.
   - Action: run `just build`, `just test`, and `just build-release` on the implementation branch; attach results and investigate failures.
   - Expected result: the application builds in Debug and Release, and the unit suite passes with the live test skipped.
   - Unverified behavior: full application integration and XCTest coverage cannot be established by the current CLI probes.
   - Release restriction: do not release implementation changes until these checks pass. Their absence does not block the documentation-only plan PR.

2. **Live display behavior and latency**
   - Responsible role: maintainer who can safely change the host's display configuration.
   - Prerequisite: a successful full build, a recoverable test setup, and explicit approval for display changes. Use macOS 14 and a current supported macOS version where available.
   - Action: run the opt-in `just test-live` test; check multiple displays, rapid source changes, disconnect during a pending operation, source reconnection, and sleep/wake. Capture a main-thread trace during mirror changes and compare notification work with the baseline.
   - Expected result: mirror intent and connection recovery remain correct, no stale operation changes the final selection, and no CoreGraphics mirror transaction occupies the main thread.
   - Unverified behavior: private API compatibility, real display recovery, menu responsiveness, and actual system latency remain unmeasured by test doubles. Record unavailable OS/device coverage rather than claiming it passed.
   - Release restriction: do not claim measured latency gains or complete live-display validation without this evidence. Treat observed safety or recovery failures as release blockers.
