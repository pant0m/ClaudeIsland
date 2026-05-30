import AppKit
import SwiftUI

// Rasterises `IconView` (Cody) into a complete macOS .iconset folder, which
// install.sh turns into AppIcon.icns via `iconutil`.

@MainActor
enum IconExporter {
    /// (filename, pixel size) for every slot iconutil expects.
    private static let slots: [(String, Int)] = [
        ("icon_16x16", 16),   ("icon_16x16@2x", 32),
        ("icon_32x32", 32),   ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// Render every pet skin in a row to one PNG — for eyeballing the animals.
    static func gallery(to path: String) {
        let styles: [PetStyle] = [.slime, .cat, .ghost, .bunny, .bear, .fox, .chick, .penguin]
        let sheet = HStack(spacing: 6) {
            ForEach(styles, id: \.self) { s in
                VStack(spacing: 4) {
                    PetView(kind: .done, tint: Color(red: 0.36, green: 0.66, blue: 1.0),
                            size: 60, staticPose: true, style: s)
                        .frame(width: 72, height: 72)
                    Text(s.rawValue).font(.system(size: 9)).foregroundStyle(.white)
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.06, green: 0.08, blue: 0.14))
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        guard let cg = r.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func write(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var ok = 0
        for (name, px) in slots {
            let renderer = ImageRenderer(content: IconView())
            renderer.scale = CGFloat(px) / 1024
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: px, height: px)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            ok += 1
        }
        FileHandle.standardError.write("wrote \(ok)/\(slots.count) icon slots to \(dir)\n"
            .data(using: .utf8)!)
    }
}
