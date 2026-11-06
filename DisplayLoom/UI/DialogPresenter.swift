import AppKit
import Foundation

@MainActor
enum DialogPresenter {
  static func confirm8K() -> Bool {
    let alert = makeAlert(
      title: String(localized: "dialog.8k.title", defaultValue: "Use an 8K virtual display?"),
      message: String(
        localized: "dialog.8k.message",
        defaultValue:
          """
          8K virtual displays use substantial memory and GPU resources. \
          Multiple high-resolution displays may reduce system stability.
          """
      ),
      style: .warning
    )
    alert.addButton(withTitle: String(localized: "dialog.continue", defaultValue: "Continue"))
    alert.addButton(withTitle: String(localized: "dialog.cancel", defaultValue: "Cancel"))
    return present(alert) == .alertFirstButtonReturn
  }

  static func requestName(currentName: String) -> String? {
    let alert = makeAlert(
      title: String(localized: "dialog.rename.title", defaultValue: "Rename Virtual Display"),
      message: String(
        localized: "dialog.rename.message",
        defaultValue: "Enter a name for this virtual display."
      ),
      style: .informational
    )
    let field = NSTextField(string: currentName)
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    field.placeholderString = String(
      localized: "dialog.rename.placeholder",
      defaultValue: "Display name"
    )
    alert.accessoryView = field
    alert.addButton(withTitle: String(localized: "dialog.rename", defaultValue: "Rename"))
    alert.addButton(withTitle: String(localized: "dialog.cancel", defaultValue: "Cancel"))

    guard present(alert) == .alertFirstButtonReturn else { return nil }
    return field.stringValue
  }

  static func confirmRemoval(name: String) -> Bool {
    let alert = makeAlert(
      title: String(localized: "dialog.remove.title", defaultValue: "Remove Virtual Display?"),
      message: String(
        format: String(
          localized: "dialog.remove.message",
          defaultValue: "“%@” and its saved settings will be removed. This can’t be undone."
        ),
        name
      ),
      style: .warning
    )
    alert.addButton(withTitle: String(localized: "dialog.remove", defaultValue: "Remove"))
    alert.addButton(withTitle: String(localized: "dialog.cancel", defaultValue: "Cancel"))
    return present(alert) == .alertFirstButtonReturn
  }

  static func showError(_ message: String) {
    let alert = makeAlert(
      title: String(localized: "dialog.error.title", defaultValue: "Display Loom Error"),
      message: message,
      style: .critical
    )
    alert.addButton(withTitle: String(localized: "dialog.ok", defaultValue: "OK"))
    _ = present(alert)
  }

  static func showLaunchAtLoginApproval(openSettings: () -> Void) {
    let alert = makeAlert(
      title: String(
        localized: "dialog.loginApproval.title",
        defaultValue: "Approve Launch at Login"
      ),
      message: String(
        localized: "dialog.loginApproval.message",
        defaultValue:
          """
          macOS requires approval before Display Loom can start at login. \
          Approve it in System Settings > General > Login Items.
          """
      ),
      style: .informational
    )
    alert.addButton(
      withTitle: String(localized: "dialog.openSettings", defaultValue: "Open Login Items")
    )
    alert.addButton(withTitle: String(localized: "dialog.later", defaultValue: "Later"))
    if present(alert) == .alertFirstButtonReturn {
      openSettings()
    }
  }

  private static func makeAlert(title: String, message: String, style: NSAlert.Style) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
    return alert
  }

  private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal()
  }
}
