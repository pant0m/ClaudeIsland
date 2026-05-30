import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Raw model: mirrors ~/.claude/island/state.json (written by claude-island.py)

struct RawSession: Decodable {
    var session_id: String?
    var cwd: String?
    var project: String?
    var state: String?        // "idle" | "working" | "attention" | "done"
    var activity: String?
    var tool: String?
    var tools_run: Int?
    var started_at: Double?
    var updated_at: Double?
    var finished_at: Double?
    var message: String?
    var pid: Int?             // owning Claude process; dead pid => zombie session
    var term: String?         // TERM_PROGRAM, for click-to-focus
    var tty: String?          // controlling tty, e.g. "ttys003" — focus the exact tab
    var ctx_tokens: Int?      // current context-window size (last assistant msg)
    var out_tokens: Int?      // cumulative output tokens this session
    var cost_usd: Double?     // estimated cumulative cost (USD)
    var files_changed: Int?   // distinct files this session edited
}

/// Shared display formatters for tokens and cost.
enum Fmt {
    static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.0fk", Double(n) / 1000) : "\(n)"
    }
    static func cost(_ c: Double) -> String { String(format: "$%.2f", c) }
}

struct RawState: Decodable {
    var sessions: [String: RawSession]?
}

// MARK: - Selected snapshot: the single session we surface in the notch

enum IslandKind: String {
    case none, working, attention, done
}

struct Snapshot: Equatable {
    var kind: IslandKind = .none
    var project: String = ""
    var activity: String = ""
    var message: String = ""
    var toolsRun: Int = 0
    var startedAt: Double?
    var finishedAt: Double?
    var activeCount: Int = 0
    var term: String = ""      // selected session's terminal + tty, for click-to-focus
    var tty: String = ""
    var cwd: String = ""
    var cost: Double = 0       // estimated cumulative cost of the selected session
    var ctxTokens: Int = 0     // current context-window fill (drives Cody's chonk)
    var filesChanged: Int = 0  // distinct files this session edited
}

enum StateSelector {
    enum Liveness { case live, deadProcess, stale }

    /// Is the owning Claude process gone? Only conclusive when we have a pid.
    static func isProcessDead(_ s: RawSession) -> Bool {
        guard let pid = s.pid, pid > 1 else { return false }
        if kill(pid_t(pid), 0) == 0 { return false }   // signalled fine -> alive
        return errno == ESRCH                           // ESRCH -> no such process
    }

    /// A session is reaped if its process died, or (legacy, pid-less) it has been
    /// silently "working" past `staleTTL`. Attention is never time-reaped — a user
    /// may legitimately be away for a long while — only its dead process reaps it.
    static func liveness(_ s: RawSession, now: Double, staleTTL: Double = 600) -> Liveness {
        if isProcessDead(s) { return .deadProcess }
        if s.pid == nil, s.state == "working", now - (s.updated_at ?? 0) > staleTTL {
            return .stale
        }
        return .live
    }

    /// Priority: anything needing attention > most-recent working > most-recent
    /// freshly-done (within `doneTTL`). Returns `.none` when nothing is active.
    static func select(_ state: RawState, now: Double, doneTTL: Double = 6) -> Snapshot {
        let sessions = Array((state.sessions ?? [:]).values)
        func live(_ s: RawSession) -> Bool { liveness(s, now: now) == .live }

        let attention = sessions.filter { $0.state == "attention" && live($0) }
        let working = sessions.filter { $0.state == "working" && live($0) }
        let done = sessions.filter {
            $0.state == "done" && now - ($0.finished_at ?? 0) < doneTTL
        }
        let activeCount = attention.count + working.count

        func newest(_ xs: [RawSession], by key: (RawSession) -> Double) -> RawSession? {
            xs.max { key($0) < key($1) }
        }

        func snap(_ s: RawSession, _ kind: IslandKind) -> Snapshot {
            Snapshot(
                kind: kind,
                project: s.project ?? "Claude",
                activity: s.activity ?? "",
                message: s.message ?? "",
                toolsRun: s.tools_run ?? 0,
                startedAt: s.started_at,
                finishedAt: s.finished_at,
                activeCount: activeCount,
                term: s.term ?? "",
                tty: s.tty ?? "",
                cwd: s.cwd ?? "",
                cost: s.cost_usd ?? 0,
                ctxTokens: s.ctx_tokens ?? 0,
                filesChanged: s.files_changed ?? 0
            )
        }

        if let s = newest(attention, by: { $0.updated_at ?? 0 }) { return snap(s, .attention) }
        if let s = newest(working, by: { $0.updated_at ?? 0 }) { return snap(s, .working) }
        if let s = newest(done, by: { $0.finished_at ?? 0 }) { return snap(s, .done) }
        return Snapshot()
    }

    /// Every session worth listing in the menu bar: live (non-zombie), recent,
    /// ranked attention > working > idle > done, then most-recently-updated.
    static func liveList(_ state: RawState, now: Double, doneTTL: Double = 900) -> [RawSession] {
        func rank(_ s: RawSession) -> Int {
            switch s.state {
            case "attention": return 0
            case "working": return 1
            case "idle": return 2
            case "done": return 3
            default: return 4
            }
        }
        func keep(_ s: RawSession) -> Bool {
            guard liveness(s, now: now) == .live else { return false }
            switch s.state {
            case "working", "attention", "idle": return true
            case "done": return now - (s.finished_at ?? 0) < doneTTL
            default: return false
            }
        }
        return Array((state.sessions ?? [:]).values).filter(keep).sorted {
            rank($0) != rank($1) ? rank($0) < rank($1)
                                 : ($0.updated_at ?? 0) > ($1.updated_at ?? 0)
        }
    }
}
