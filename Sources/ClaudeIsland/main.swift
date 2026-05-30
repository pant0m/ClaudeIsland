import AppKit

// Menu-bar agent that watches ~/.claude/island/state.json and drives the notch.

/// Click target carried on each menu item so we know which terminal to raise.
final class FocusTarget {
    let term: String, tty: String, cwd: String
    init(term: String, tty: String, cwd: String) { self.term = term; self.tty = tty; self.cwd = cwd }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = NotchController()
    private var pollTask: Task<Void, Never>?
    private var dirSource: DispatchSourceFileSystemObject?
    private var lastSnapshot = Snapshot()
    private let decoder = JSONDecoder()
    private var gitCache: [String: (info: String, at: Date)] = [:]
    private var notifiedAttention: Set<String> = []

    private var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/island/state.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles",
                                           accessibilityDescription: "Claude Island")

        // Built lazily on open via NSMenuDelegate so it's always current.
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        FirstRun.setUpIfNeeded()          // pre-built .app: wire hooks + autostart on first run
        startWatching()
        Notifier.requestAuthorization()   // one-time prompt -> native, branded banners

        // FSEvents handles file writes; this slow poll only re-evaluates the
        // time-based stuff that happens with no write (a session's process dying).
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// React the instant the producer rewrites state.json. We watch the containing
    /// directory, not the file: the producer replaces state.json with an atomic
    /// rename, swapping its inode every write, which would kill a file-fd watch.
    private func startWatching() {
        let fd = open(stateURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }   // no watch -> the 2s poll still covers us
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    private func loadRawState() -> RawState {
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? decoder.decode(RawState.self, from: data) {
            return decoded
        }
        return RawState(sessions: [:])
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        let raw = loadRawState()
        let snap = StateSelector.select(raw, now: now)

        // Apply config every tick (it lives in the watched dir) so edits to
        // config.json reflect live, even when the session snapshot is unchanged.
        let cfg = PetConfig.load()
        let style = cfg.petStyle
        let hex = cfg.colorHex(forProject: snap.project)
        if controller.model.style != style { controller.model.style = style }
        if controller.model.configColorHex != hex { controller.model.configColorHex = hex }

        let branch = gitInfo(snap.cwd)
        if controller.model.branch != branch { controller.model.branch = branch }

        // Per-session attention banners: one per session entering attention,
        // independent of which session the notch happens to surface.
        var attnNow: Set<String> = []
        for (id, s) in raw.sessions ?? [:]
            where s.state == "attention" && StateSelector.liveness(s, now: now) == .live {
            attnNow.insert(id)
            if !notifiedAttention.contains(id) {
                Notifier.attention(project: s.project ?? "", message: s.message ?? "")
            }
        }
        notifiedAttention = attnNow

        guard snap != lastSnapshot else { return }
        lastSnapshot = snap
        controller.present(snap)
        updateStatusItem(snap)
    }

    // MARK: - Live session menu

    /// Rebuild the dropdown right before it opens: one row per live session.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let now = Date().timeIntervalSince1970
        let list = StateSelector.liveList(loadRawState(), now: now)
        let active = list.filter { $0.state == "working" || $0.state == "attention" }.count

        menu.removeAllItems()
        let header = NSMenuItem(title: active > 0 ? "Claude Island — \(active) 活跃" : "Claude Island",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if list.isEmpty {
            let empty = NSMenuItem(title: "无活跃会话", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for s in list { menu.addItem(sessionItem(s, now: now)) }
        }

        let totalCost = list.reduce(0.0) { $0 + ($1.cost_usd ?? 0) }
        let totalOut = list.reduce(0) { $0 + ($1.out_tokens ?? 0) }
        if totalCost > 0 {
            menu.addItem(.separator())
            let foot = NSMenuItem(title: "合计 ≈ \(Fmt.cost(totalCost)) · 输出 \(Fmt.tokens(totalOut))",
                                  action: nil, keyEquivalent: "")
            foot.isEnabled = false
            menu.addItem(foot)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Claude Island",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func sessionItem(_ s: RawSession, now: Double) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(focusSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = FocusTarget(term: s.term ?? "", tty: s.tty ?? "", cwd: s.cwd ?? "")

        let dot: NSColor
        switch s.state {
        case "attention": dot = .systemOrange
        case "working":   dot = .systemBlue
        case "done":      dot = .systemGreen
        default:          dot = .systemGray
        }

        let clock: String
        switch s.state {
        case "working": clock = s.started_at.map { ElapsedText.fmt(now - $0) } ?? ""
        case "done":
            if let st = s.started_at, let fin = s.finished_at { clock = ElapsedText.fmt(fin - st) }
            else { clock = "" }
        case "attention": clock = "等 " + (s.updated_at.map { ElapsedText.fmt(now - $0) } ?? "0:00")
        default: clock = ""
        }

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dot]))
        title.append(NSAttributedString(string: s.project ?? "Claude",
            attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        let git = gitInfo(s.cwd ?? "")
        if !git.isEmpty {
            title.append(NSAttributedString(string: " \(git)",
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        if !clock.isEmpty {
            title.append(NSAttributedString(string: "   \(clock)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        var stat = ""
        if let ctx = s.ctx_tokens, ctx > 0 { stat += " \(Fmt.tokens(ctx))" }
        if let fc = s.files_changed, fc > 0 { stat += " ✎\(fc)" }
        if let c = s.cost_usd, c > 0 { stat += " ≈\(Fmt.cost(c))" }
        if !stat.isEmpty {
            title.append(NSAttributedString(string: "  \(stat.trimmingCharacters(in: .whitespaces))",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let activity = String((s.activity ?? "").prefix(28))
        if !activity.isEmpty {
            title.append(NSAttributedString(string: "   \(activity)",
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        item.attributedTitle = title

        let stateCN = ["working": "工作中", "attention": "需要介入",
                       "done": "完成", "idle": "就绪"][s.state ?? ""] ?? (s.state ?? "")
        item.toolTip = "\(s.project ?? "") · \(stateCN)\n\(s.cwd ?? "")"
        if (s.tty ?? "").isEmpty && (s.term ?? "").isEmpty { item.isEnabled = false }
        return item
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? FocusTarget else { return }
        TerminalFocus.focus(term: t.term, tty: t.tty, cwd: t.cwd)
    }

    /// "(branch*)" for a session's cwd, or "" if not a git repo. Runs git only on
    /// menu open, so it's off the hot path.
    private func gitInfo(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        if let c = gitCache[cwd], Date().timeIntervalSince(c.at) < 10 { return c.info }  // TTL cache
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", cwd] + args
            let out = Pipe()
            p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let info: String
        if var branch = git(["rev-parse", "--abbrev-ref", "HEAD"]), !branch.isEmpty {
            if branch == "HEAD" { branch = git(["rev-parse", "--short", "HEAD"]) ?? "HEAD" }  // detached
            let dirty = !(git(["status", "--porcelain"]) ?? "").isEmpty
            info = "(\(branch)\(dirty ? "*" : ""))"
        } else {
            info = ""
        }
        gitCache[cwd] = (info, Date())
        return info
    }

    private func updateStatusItem(_ s: Snapshot) {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch s.kind {
        case .none: symbol = "sparkles"
        case .working: symbol = "circle.dotted"
        case .attention: symbol = "bell.badge.fill"
        case .done: symbol = "checkmark.circle.fill"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Island")
        button.toolTip = s.kind == .none ? "Claude Island" : "\(s.project) · \(s.activity)"
    }
}

// Diagnostic: `ClaudeIsland --dump` prints each session's liveness + the chosen
// snapshot, then exits. Handy for confirming zombie reaping without the GUI.
if CommandLine.arguments.contains("--dump") {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/island/state.json")
    let now = Date().timeIntervalSince1970
    let raw = (try? JSONDecoder().decode(RawState.self, from: Data(contentsOf: url)))
        ?? RawState(sessions: [:])
    for s in (raw.sessions ?? [:]).values.sorted(by: { ($0.updated_at ?? 0) > ($1.updated_at ?? 0) }) {
        let age = Int(now - (s.updated_at ?? 0))
        let verdict = StateSelector.liveness(s, now: now)
        let cost = s.cost_usd.map { String(format: "≈$%.2f", $0) } ?? "—"
        let ctx = s.ctx_tokens.map { Fmt.tokens($0) } ?? "—"
        print("\(s.project ?? "?")\tstate=\(s.state ?? "?")\tage=\(age)s\tpid=\(s.pid.map(String.init) ?? "—")\tctx=\(ctx)\t\(cost)\t\(verdict)")
    }
    let snap = StateSelector.select(raw, now: now)
    print("SELECTED -> \(snap.kind) \(snap.project)  active=\(snap.activeCount)")
    print("--- 菜单列表(liveList,排序后)---")
    for s in StateSelector.liveList(raw, now: now) {
        let focusable = !((s.tty ?? "").isEmpty && (s.term ?? "").isEmpty)
        print("● \(s.project ?? "?")\t\(s.state ?? "?")\tterm=\(s.term ?? "—")\ttty=\(s.tty ?? "—")\tfocusable=\(focusable)")
    }
    exit(0)
}

// Diagnostic: `ClaudeIsland --focus <TERM_PROGRAM> <tty>` exercises click-to-focus
// without the GUI, e.g. `--focus Apple_Terminal ttys003`.
if let i = CommandLine.arguments.firstIndex(of: "--focus") {
    let a = CommandLine.arguments
    TerminalFocus.focus(term: i + 1 < a.count ? a[i + 1] : "",
                        tty: i + 2 < a.count ? a[i + 2] : "",
                        cwd: "")
    Thread.sleep(forTimeInterval: 1.0)   // let osascript finish before we exit
    exit(0)
}

// `ClaudeIsland --icon <dir>` renders Cody into a macOS .iconset, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--icon") {
    let dir = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "AppIcon.iconset"
    _ = NSApplication.shared    // initialise AppKit so ImageRenderer can rasterise
    IconExporter.write(to: dir)
    exit(0)
}

// `ClaudeIsland --gallery <png>` renders all pet skins to one image, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--gallery") {
    _ = NSApplication.shared
    IconExporter.gallery(to: i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/gallery.png")
    exit(0)
}

// Diagnostic: `ClaudeIsland --notify` fires a sample attention banner and exits.
if CommandLine.arguments.contains("--notify") {
    Notifier.attention(project: "demo-project", message: "需要你确认一个权限请求")
    Thread.sleep(forTimeInterval: 1.0)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
