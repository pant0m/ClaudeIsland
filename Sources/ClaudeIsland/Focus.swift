import AppKit
import UserNotifications

// MARK: - Click the notch -> raise the terminal that owns the selected session
//
// The hook records each session's TERM_PROGRAM and controlling tty. For Terminal
// and iTerm we can pinpoint the exact window/tab by tty; for everything else we
// fall back to bringing the terminal app forward.

enum TerminalFocus {
    static func focus(term: String, tty: String, cwd: String) {
        let dev = tty.isEmpty ? "" : (tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)")

        switch term {
        case "Apple_Terminal":
            dev.isEmpty ? activate("com.apple.Terminal") : osa(terminalScript(dev))
        case "iTerm.app":
            dev.isEmpty ? activate("com.googlecode.iterm2") : osa(itermScript(dev))
        default:
            if let bundle = bundleID(for: term) { activate(bundle) }
        }
    }

    // MARK: AppleScript — find the tab whose tty matches, select it, raise its window

    private static func terminalScript(_ dev: String) -> String {
        """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(dev)" then
                set selected of t to true
                set frontmost of w to true
                return
              end if
            end repeat
          end repeat
        end tell
        """
    }

    private static func itermScript(_ dev: String) -> String {
        """
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(dev)" then
                  select w
                  select t
                  select s
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
    }

    // MARK: helpers

    /// Spawn osascript (safe off any thread, never blocks the UI).
    private static func osa(_ source: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        try? p.run()
    }

    private static func activate(_ bundleID: String) {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: bundleID) else { return }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Best-effort TERM_PROGRAM -> bundle id for terminals we can't tty-target.
    private static func bundleID(for term: String) -> String? {
        switch term {
        case "vscode":                return "com.microsoft.VSCode"
        case "ghostty", "Ghostty":    return "com.mitchellh.ghostty"
        case "WezTerm":               return "com.github.wez.wezterm"
        case "Hyper":                 return "co.zeit.hyper"
        case "Tabby":                 return "org.tabby"
        case "WarpTerminal", "Warp":  return "dev.warp.Warp-Stable"
        case "kitty":                 return "net.kovidgoyal.kitty"
        case "Alacritty":             return "org.alacritty"
        default:                      return nil
        }
    }
}

// MARK: - Notifications
//
// We post via `osascript display notification` rather than NSSound.beep(): the
// banner AND its sound are then held automatically by macOS during Focus/DND and
// (per the user's Notification settings) while sharing the screen — so "do not
// disturb" comes for free from the OS instead of fragile state detection.

enum Notifier {
    /// Ask once on launch so attention banners can use the native, branded path
    /// (shows as "ClaudeIsland" + the app icon, configurable under its own name).
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func attention(project: String, message: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = project.isEmpty ? "Claude" : project
                content.subtitle = "需要你介入"
                content.body = message.isEmpty ? "等待你的输入" : message
                content.sound = .default
                let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(req, withCompletionHandler: nil)
            default:
                osascriptNotify(project: project, message: message)
            }
        }
    }

    /// Fallback when native notifications aren't authorised — shows under the
    /// osascript ("Script Editor") identity, but always works.
    private static func osascriptNotify(project: String, message: String) {
        let subtitle = project.isEmpty ? "需要你介入" : "\(project) · 需要你介入"
        let body = message.isEmpty ? "等待你的输入" : message
        let script = "display notification \(esc(body)) with title \"ClaudeIsland\" "
            + "subtitle \(esc(subtitle)) sound name \"Submarine\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    /// Quote + escape a Swift string as an AppleScript string literal.
    private static func esc(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
