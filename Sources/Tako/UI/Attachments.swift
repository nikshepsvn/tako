import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files and images dropped onto a message field become paths in the message, which Claude Code
/// and Codex read as attachments. Images without a file (dragged from a browser, pasted) are
/// saved to ~/.hyperterm/attachments first.
enum Attachments {
    static var directory: URL { ControlPaths.supportDirectory.appendingPathComponent("attachments") }

    static let types: [UTType] = [.fileURL, .image]

    /// Resolves dropped items to file paths, then hands them back on the main actor.
    static func paths(from providers: [NSItemProvider], completion: @escaping @MainActor ([String]) -> Void) -> Bool {
        let group = DispatchGroup()
        let found = Found()
        for (index, provider) in providers.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { found.add(index, url.path) }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data, let path = save(imageData: data) { found.add(index, path) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let ordered = found.ordered
            MainActor.assumeIsolated { completion(ordered) }
        }
        return !providers.isEmpty
    }

    /// Collects results from the providers' background callbacks.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Int, String)] = []

        func add(_ index: Int, _ path: String) {
            lock.lock()
            items.append((index, path))
            lock.unlock()
        }

        var ordered: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Writes image data as a PNG and returns its path.
    static func save(imageData: Data) -> String? {
        guard let image = NSImage(data: imageData), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("image-\(UUID().uuidString.prefix(8)).png")
        return (try? png.write(to: url)) != nil ? url.path : nil
    }

    /// Paths as they go into a prompt: quoted when they contain spaces.
    static func text(for paths: [String]) -> String {
        paths.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

extension View {
    /// Accepts dropped files and images, appending their paths to `text`.
    func acceptsAttachments(_ text: Binding<String>) -> some View {
        onDrop(of: Attachments.types, isTargeted: nil) { providers in
            Attachments.paths(from: providers) { paths in
                guard !paths.isEmpty else { return }
                let joined = Attachments.text(for: paths)
                text.wrappedValue += (text.wrappedValue.isEmpty || text.wrappedValue.hasSuffix(" ") ? "" : " ") + joined + " "
            }
        }
    }
}
