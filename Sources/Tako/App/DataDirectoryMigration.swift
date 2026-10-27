import Foundation

/// Moves data kept under the pre-rename name to Tako's, once, at launch and before anything
/// reads the support folder: ~/.hyperterm becomes ~/.tako, and Chromium's download cache
/// ~/Library/Caches/Hyperterm/cef becomes ~/Library/Caches/Tako/cef.
///
/// Each move is a single rename(2): the folders hold git worktrees and the browser profile's
/// logins, so a copy-then-delete that could stop halfway (or cross volumes) is never attempted.
/// The old path is left as a symlink to the new one for good, because absolute ~/.hyperterm paths
/// live on outside Tako: the user's PATH line, git worktree metadata, saved session folders and
/// agent configs. Anything unexpected leaves both paths as they were.
enum DataDirectoryMigration {
    enum Outcome: Equatable {
        /// Nothing at the old path: a fresh install, or one made after the rename.
        case nothingToMove
        /// The old path is already a symlink: an earlier launch moved it.
        case alreadyDone
        case moved
        /// Both exist as real folders (the user made one, or an old build ran after the move).
        /// The new one is used; the old one is left for the user to look through.
        case bothExist
        case failed(String)
    }

    static func runAtLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) {
        // A test host must never move the user's real data.
        guard environment["XCTestConfigurationFilePath"] == nil else { return }
        let fm = FileManager.default
        // $HT_HOME (a dev build) names its own folder; the installed app's data isn't its to move.
        if (environment["HT_HOME"] ?? "").isEmpty {
            log("data folder", migrateSupportDirectory(home: fm.homeDirectoryForCurrentUser))
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            log("browser cache", migrateBrowserCache(caches: caches))
        }
    }

    static func migrateSupportDirectory(home: URL) -> Outcome {
        move(home.appendingPathComponent(ControlPaths.legacyDirectoryName),
             to: home.appendingPathComponent(ControlPaths.directoryName))
    }

    static func migrateBrowserCache(caches: URL) -> Outcome {
        move(caches.appendingPathComponent("Hyperterm/cef"), to: caches.appendingPathComponent("Tako/cef"))
    }

    /// Renames `old` to `new` and links `old` to it. Undoes the rename if the link can't be made,
    /// so a half-done move never strands the paths others hold.
    static func move(_ old: URL, to new: URL) -> Outcome {
        guard let kind = fileType(old) else { return .nothingToMove }
        if kind == .typeSymbolicLink { return .alreadyDone }
        guard kind == .typeDirectory else { return .failed("\(old.path) is not a folder") }
        // lstat, so even a dangling symlink at the new path counts as taken.
        if fileType(new) != nil { return .bothExist }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed("can't create \(new.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        // rename(2), not moveItem: moveItem falls back to copying across volumes.
        guard rename(old.path, new.path) == 0 else {
            return .failed("rename \(old.path) → \(new.path): \(String(cString: strerror(errno)))")
        }
        do {
            try fm.createSymbolicLink(atPath: old.path, withDestinationPath: new.path)
        } catch {
            let reason = error.localizedDescription
            guard rename(new.path, old.path) == 0 else {
                return .failed("moved to \(new.path) but couldn't link \(old.path) (\(reason)) or move it back")
            }
            return .failed("couldn't link \(old.path), left it in place: \(reason)")
        }
        return .moved
    }

    private static func fileType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    private static func log(_ what: String, _ outcome: Outcome) {
        switch outcome {
        case .nothingToMove, .alreadyDone: return
        case .moved: NSLog("tako: moved %@ to its new name", what)
        case .bothExist: NSLog("tako: %@ exists under both its old and new names; using the new one", what)
        case .failed(let reason): NSLog("tako: couldn't move %@: %@", what, reason)
        }
    }
}
