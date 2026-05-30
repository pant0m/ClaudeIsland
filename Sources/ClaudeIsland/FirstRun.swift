import AppKit

// For the pre-built .app: on first launch, offer to wire the Claude Code hooks and
// set up login autostart, so a downloaded app is self-sufficient. The hook script
// is bundled in Resources/ (install.sh puts it there); a plain `swift build` has no
// bundled hook, so this is a no-op for dev builds.

enum FirstRun {
    static func setUpIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settings = home.appendingPathComponent(".claude/settings.json")
        guard let bundledHook = Bundle.main.url(forResource: "claude-island", withExtension: "py")
        else { return }                          // dev build: nothing bundled
        if hooksAlreadyWired(settings) { return } // already set up

        NSApp.activate(ignoringOtherApps: true)
        let ask = NSAlert()
        ask.messageText = "Set up Claude Island?"
        ask.informativeText = """
        Claude Island adds lightweight hooks to Claude Code so it can show your \
        sessions in the notch, and starts on login. It only writes a tiny local \
        JSON file — no network, no side effects.
        """
        ask.addButton(withTitle: "Set Up")
        ask.addButton(withTitle: "Not Now")
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        installHook(from: bundledHook)
        wireSettings(at: settings)
        installAutostart()

        let done = NSAlert()
        done.messageText = "Claude Island is ready."
        done.informativeText = "It’s monitoring Claude Code and starts on login. "
            + "Customise the pet in ~/.claude/island/config.json."
        done.runModal()
    }

    private static func hooksAlreadyWired(_ settings: URL) -> Bool {
        guard let s = try? String(contentsOf: settings, encoding: .utf8) else { return false }
        return s.contains("claude-island.py")
    }

    private static func installHook(from bundled: URL) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/island")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("claude-island.py")
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: bundled, to: dst)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
    }

    private static func wireSettings(at url: URL) {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let cmd = "$HOME/.claude/island/claude-island.py"
        for e in ["SessionStart", "UserPromptSubmit", "PreToolUse",
                  "PostToolUse", "Notification", "Stop", "SessionEnd"] {
            var arr = hooks[e] as? [[String: Any]] ?? []
            arr.append(["hooks": [["type": "command", "command": "\(cmd) \(e)"]]])
            hooks[e] = arr
        }
        root["hooks"] = hooks
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? out.write(to: url)
        }
    }

    private static func installAutostart() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.claudeisland.plist")
        let exe = Bundle.main.executablePath ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>com.claudeisland</string>
          <key>ProgramArguments</key><array><string>\(exe)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><false/>
          <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? xml.write(to: plist, atomically: true, encoding: .utf8)
        let uid = getuid()
        run("/bin/launchctl", ["bootout", "gui/\(uid)/com.claudeisland"])
        run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist.path])
    }

    private static func run(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
