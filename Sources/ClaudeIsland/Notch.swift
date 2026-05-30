import AppKit
import DynamicNotchKit
import SwiftUI

// MARK: - Observable display model (views watch this; updates render live)

@MainActor
final class IslandModel: ObservableObject {
    @Published var kind: IslandKind = .none
    @Published var project = ""
    @Published var activity = ""
    @Published var message = ""
    @Published var toolsRun = 0
    @Published var startedAt: Date?
    @Published var finishedAt: Date?
    @Published var activeCount = 0
    @Published var asleep = false      // UI-only: Cody naps after a done before hiding

    @Published var cost: Double = 0
    @Published var ctxTokens = 0
    @Published var filesChanged = 0
    @Published var branch = ""         // "(main*)" for the surfaced session, set by the poll
    @Published var boopAt: Date?       // bumped on click -> Cody's petting reaction
    @Published var configColorHex: String?   // working-state colour from config.json
    @Published var style: PetStyle = .slime  // skin from config.json

    /// Hover over the notch -> expand to the detail card (wired by the controller).
    var hoverHandler: ((Bool) -> Void)?

    // Click-to-focus target of the surfaced session (not @Published — read on tap).
    var term = ""
    var tty = ""
    var cwd = ""

    /// Cody's chonk: 0…1 as the context window fills (≈180k = stuffed).
    var fatness: CGFloat { min(1, CGFloat(ctxTokens) / 180_000) }
    /// Start of the current turn while working — feeds the tiredness ramp.
    var workingSince: Date? { kind == .working ? startedAt : nil }

    func apply(_ s: Snapshot) {
        kind = s.kind
        project = s.project
        activity = s.activity
        message = s.message
        toolsRun = s.toolsRun
        startedAt = s.startedAt.map { Date(timeIntervalSince1970: $0) }
        finishedAt = s.finishedAt.map { Date(timeIntervalSince1970: $0) }
        activeCount = s.activeCount
        cost = s.cost
        ctxTokens = s.ctxTokens
        filesChanged = s.filesChanged
        term = s.term
        tty = s.tty
        cwd = s.cwd
    }

    var tint: Color {
        switch kind {
        case .none, .working: return configColorHex.flatMap(Color.init(hex:)) ?? .blue
        case .attention: return .orange      // kept semantic regardless of config
        case .done: return .green
        }
    }
}

// MARK: - Controller: maps model state -> DynamicNotch expand/compact/hide

@MainActor
final class NotchController {
    let model = IslandModel()
    private var notch: DynamicNotch<ExpandedView, CompactLeadingView, CompactTrailingView>!
    private var shown: IslandKind = .none
    private var doneHideToken = 0
    private let hasNotch: Bool
    private var isHovering = false
    private var hoverTimer: Timer?

    init() {
        hasNotch = Self.detectNotch()
        let model = self.model
        notch = DynamicNotch(
            expanded: { ExpandedView(model: model) },
            compactLeading: { CompactLeadingView(model: model) },
            compactTrailing: { CompactTrailingView(model: model) }
        )
        model.hoverHandler = { [weak self] in self?.setHover($0) }
    }

    /// Hovering a compact working pill expands it to the detail card. We then poll
    /// the mouse location to detect leaving — `.onHover`'s exit event is unreliable
    /// in a non-key panel — so the pill reliably restores when the cursor leaves.
    func setHover(_ hovering: Bool) {
        guard hovering, hasNotch, shown == .working, !isHovering else { return }
        isHovering = true
        Task { await notch.expand() }
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.shown != .working || !self.mouseInNotchZone() { self.endHover() }
            }
        }
    }

    private func endHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        let wasWorking = shown == .working
        isHovering = false
        if wasWorking, hasNotch { Task { await notch.compact() } }
    }

    /// Is the cursor still in the notch's top-centre region (notch + the card)?
    private func mouseInNotchZone() -> Bool {
        guard let screen = NSScreen.main else { return false }
        let f = screen.frame
        let p = NSEvent.mouseLocation
        return p.y > f.maxY - 160 && abs(p.x - f.midX) < 230
    }

    static func detectNotch() -> Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }

    func present(_ snapshot: Snapshot) {
        model.apply(snapshot)
        if snapshot.kind != .done { model.asleep = false }   // wake on any new activity

        let kind = snapshot.kind
        guard kind != shown else { return }
        let previous = shown
        shown = kind
        if kind != .working { endHover() }   // leaving working cancels any hover-expand

        switch kind {
        case .none:
            Task { await notch.hide() }

        case .working:
            // Notched Macs get the ambient compact pill (expanded while hovered);
            // others always get the floating panel.
            if hasNotch && !isHovering {
                Task { await notch.compact() }
            } else {
                Task { await notch.expand() }
            }

        case .attention:
            // Banner+sound (OS holds both during Focus/DND) instead of a raw beep.
            if previous != .attention {
                Notifier.attention(project: snapshot.project, message: snapshot.message)
            }
            Task { await notch.expand() }

        case .done:
            model.asleep = false
            Task { await notch.expand() }
            doneHideToken += 1
            let token = doneHideToken
            Task { [weak self] in
                // Celebrate, then lie down for a nap, then quietly slip away.
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.doneHideToken == token, self.shown == .done else { return }
                self.model.asleep = true
                try? await Task.sleep(for: .seconds(3))
                guard self.doneHideToken == token, self.shown == .done else { return }
                self.shown = .none
                await self.notch.hide()
            }
        }
    }
}

// MARK: - SwiftUI content

/// Make a notch view clickable: tap raises the owning terminal; hover shows a hand.
struct ClickToFocus: ViewModifier {
    @ObservedObject var model: IslandModel
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                model.boopAt = Date()   // pet Cody on the way out
                TerminalFocus.focus(term: model.term, tty: model.tty, cwd: model.cwd)
            }
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                model.hoverHandler?(inside)
            }
    }
}

extension View {
    func clickToFocus(_ model: IslandModel) -> some View { modifier(ClickToFocus(model: model)) }
}

/// mm:ss elapsed; live-ticking while running, frozen once finished.
struct ElapsedText: View {
    let start: Date?
    let end: Date?

    var body: some View {
        if let start {
            if let end {
                Text(Self.fmt(end.timeIntervalSince(start)))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.fmt(ctx.date.timeIntervalSince(start)))
                }
            }
        } else {
            Text("")
        }
    }

    static func fmt(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Left of the physical notch: Cody the slime + project initial.
struct CompactLeadingView: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        HStack(spacing: 5) {
            PetView(kind: model.kind, tint: model.tint, size: 20,
                    fatness: model.fatness, workingSince: model.workingSince,
                    boopAt: model.boopAt, style: model.style)
            Text(String(model.project.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.leading, 10)
        .frame(height: 26)
        .clickToFocus(model)
    }
}

/// Right of the physical notch: elapsed clock / status glyph.
struct CompactTrailingView: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        Group {
            switch model.kind {
            case .working:
                ElapsedText(start: model.startedAt, end: nil)
            case .done:
                ElapsedText(start: model.startedAt, end: model.finishedAt)
            case .attention:
                Image(systemName: "bell.fill").foregroundStyle(.orange)
            case .none:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.trailing, 10)
        .frame(height: 26)
        .clickToFocus(model)
    }
}

/// Expanded panel under the notch: icon + project + activity + elapsed/steps.
struct ExpandedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(model.tint.opacity(0.16)).frame(width: 40, height: 40)
                PetView(kind: model.kind, tint: model.tint, size: 30, asleep: model.asleep,
                        fatness: model.fatness, workingSince: model.workingSince,
                        boopAt: model.boopAt, style: model.style)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.project)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    if !model.branch.isEmpty {
                        Text(model.branch)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    if model.activeCount > 1 {
                        Text("\(model.activeCount)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.18)))
                            .foregroundStyle(.white)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                ElapsedText(start: model.startedAt, end: model.kind == .done ? model.finishedAt : nil)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                if !statsLine.isEmpty {
                    Text(statsLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                if model.ctxTokens > 0 {
                    Text(Fmt.tokens(model.ctxTokens))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                if model.cost > 0 {
                    Text("≈\(Fmt.cost(model.cost))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 360)
        .clickToFocus(model)
    }

    /// "N 步 · ✎M" — tool calls and files touched this session.
    private var statsLine: String {
        var parts: [String] = []
        if model.toolsRun > 0 { parts.append("\(model.toolsRun) 步") }
        if model.filesChanged > 0 { parts.append("✎\(model.filesChanged)") }
        return parts.joined(separator: " · ")
    }

    private var subtitle: String {
        if model.asleep { return "打了个盹,等下一个任务… 💤" }
        if model.kind == .attention, !model.message.isEmpty { return model.message }
        return model.activity.isEmpty ? "工作中…" : model.activity
    }
}
