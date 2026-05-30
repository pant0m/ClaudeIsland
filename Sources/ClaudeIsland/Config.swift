import Foundation
import SwiftUI

// MARK: - Live pet customisation
//
// Read from ~/.claude/island/config.json (in the dir the app already watches via
// FSEvents, so edits apply live, no restart):
//
//   { "style": "slime|cat|ghost",
//     "color": "#4aa3ff",
//     "projects": { "my-project": "#ff7eb6" } }

enum PetStyle: String {
    case slime, cat, ghost, bunny, bear, fox, chick, penguin
}

struct PetConfig: Decodable {
    var style: String?
    var color: String?
    var projects: [String: String]?

    static func load() -> PetConfig {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/island/config.json")
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(PetConfig.self, from: data)
        else { return PetConfig() }
        return cfg
    }

    var petStyle: PetStyle { PetStyle(rawValue: style ?? "") ?? .slime }

    /// Working-state colour for a project: per-project override, else the global
    /// colour, else nil (fall back to the built-in blue). attention/done keep
    /// their semantic orange/green regardless.
    func colorHex(forProject project: String) -> String? {
        projects?[project] ?? color
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}
