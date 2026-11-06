import Foundation

@main
struct PerformanceCheckMain {
  static func main() async throws {
    try await BackendPerformanceChecks.run()
    try await PerformanceChecks.run()
    print("PASS: all display performance checks (no live display changes)")
  }
}
