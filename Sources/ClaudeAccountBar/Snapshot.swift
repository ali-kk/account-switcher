import AppKit
import SwiftUI

/// Developer aid: `ClaudeAccountBar --snapshot <dir>` renders the menu with live data to
/// light.png and dark.png and exits, so the UI can be checked without clicking the menu bar.
@MainActor
enum Snapshot {
    static func write(model: AppModel, to dir: String) async {
        await model.refresh()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let view = MenuView(model: model)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .environment(\.snapshotMode, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
