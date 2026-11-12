import Foundation
import SwiftUI

@main
struct DisplayLoomApp: App {
  @StateObject private var store: VirtualDisplayStore

  init() {
    let store = VirtualDisplayStore()
    _store = StateObject(wrappedValue: store)

    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
      Task { @MainActor in
        await store.start()
      }
    }
  }

  var body: some Scene {
    Window("Display Loom", id: DisplayManagerView.windowID) {
      DisplayManagerView(store: store)
    }
    .defaultSize(width: 760, height: 560)
    .windowResizability(.contentMinSize)

    MenuBarExtra(
      content: {
        MenuBarContent(store: store)
      },
      label: {
        Label("Display Loom", systemImage: "display.2")
          .labelStyle(.iconOnly)
      }
    )
    .menuBarExtraStyle(.menu)
  }
}
