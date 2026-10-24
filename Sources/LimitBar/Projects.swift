import Foundation

/// Names the projects that working folders belong to, as the logs record them. Claude Code and
/// Codex note the folder each reply was written in, which is often deep inside a project
/// (…/LimitBar/Sources/LimitBar, …/ClawdPet/app/src/main/java/…).
enum ProjectFolder {
    /// Work that isn't in one project: chats started without a folder, and folders that hold
    /// several projects (like ~/Claude REA/Progetti).
    static let other = "Altro"

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Where the apps put the folders of chats started without one, and how deep those folders
    /// sit: Claude's scratch-workspaces/<id>/<id>/<chat> and Codex's ~/Documents/Codex/<date>/<chat>.
    private static let scratchRoots: [(path: String, depth: Int)] = [
        (home + "/Library/Application Support/Claude/scratch-workspaces", 3),
        (home + "/Documents/Codex", 2),
    ]

    /// Files at the top of a project: a repository, a package, a build setup.
    private static let rootFiles = [
        ".git", "Package.swift", "settings.gradle", "settings.gradle.kts", "package.json",
        "Cargo.toml", "pyproject.toml", "go.mod",
    ]
    private static let rootExtensions: Set<String> = ["xcodeproj", "xcworkspace"]

    /// Folders that hold a project's code rather than being the project.
    private static let sourceFolders: Set<String> = ["Sources", "Tests", "src", "app", "lib", "test", "tests"]

    struct Project: Equatable {
        /// The project's name, or `other`.
        let name: String
        /// The folder the project lives in, when it still exists; nil for `other`.
        let folder: String?
    }

    /// The project of each folder. They're named together because a folder that has since been
    /// renamed or deleted only shows it held other projects through the folders recorded inside it.
    static func projects(for folders: Set<String>) -> [String: Project] {
        var namer = Namer(folders: folders)
        return Dictionary(uniqueKeysWithValues: folders.map { ($0, namer.project($0)) })
    }

    private struct Namer {
        let folders: Set<String>
        private var inside: [String: Set<String>] = [:]
        private var named: [String: Project] = [:]

        init(folders: Set<String>) { self.folders = folders }

        /// 1. The nearest enclosing folder that starts a project.
        /// 2. Inside a scratch chat with no such folder: `other`.
        /// 3. A folder that still exists: `other` if it holds other projects; otherwise, if an
        ///    enclosing folder holds projects, the folder just inside that one
        ///    (…/Downloads/HarmonyOS Whatsapp/specs is HarmonyOS Whatsapp); otherwise the folder itself.
        /// 4. A folder that's gone: the folder above its source folders, or the folder itself;
        ///    `other` if folders recorded inside it belong to other projects.
        mutating func project(_ path: String) -> Project {
            if let project = named[path] { return project }
            let project = resolve(path)
            named[path] = project
            return project
        }

        private mutating func resolve(_ path: String) -> Project {
            let other = Project(name: ProjectFolder.other, folder: nil)
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let parts = url.pathComponents
            guard !path.isEmpty, parts.count > 1, url.path != home else { return other }

            // Inside a scratch chat only a project made within its folder counts, not the folder itself.
            let scratch = scratchRoots.first { parts.starts(with: URL(fileURLWithPath: $0.path).pathComponents) }
            let shallowest = scratch.map { URL(fileURLWithPath: $0.path).pathComponents.count + $0.depth + 1 } ?? 2
            var folder = url
            while folder.pathComponents.count >= shallowest, folder.path != home {
                if isProjectRoot(folder) { return Project(name: folder.lastPathComponent, folder: folder.path) }
                folder.deleteLastPathComponent()
            }
            if scratch != nil { return other }

            if FileManager.default.fileExists(atPath: url.path) {
                let name = url.lastPathComponent
                if projects(in: url).contains(where: { $0 != name }) || holdsOtherWork(url, name: name) { return other }
                var child = url, parent = url.deletingLastPathComponent()
                while parent.pathComponents.count > 1, parent.path != home {
                    if !projects(in: parent).isEmpty { return Project(name: child.lastPathComponent, folder: child.path) }
                    child = parent
                    parent.deleteLastPathComponent()
                }
                return Project(name: name, folder: url.path)
            }

            let source = parts.firstIndex(where: sourceFolders.contains)
            let name = source.map { $0 > 1 ? parts[$0 - 1] : url.lastPathComponent } ?? url.lastPathComponent
            return holdsOtherWork(url, name: name) ? other : Project(name: name, folder: nil)
        }

        /// Whether a recorded folder inside this one belongs to a different project.
        private mutating func holdsOtherWork(_ url: URL, name: String) -> Bool {
            let prefix = url.path + "/"
            for inner in folders where inner.hasPrefix(prefix) {
                let innerName = project(inner).name
                if innerName != name && innerName != ProjectFolder.other { return true }
            }
            return false
        }

        /// The projects that start in the folder's subfolders, or theirs (~/Downloads/ClawdPet/ClawdPet).
        private mutating func projects(in url: URL) -> Set<String> {
            if let known = inside[url.path] { return known }
            var found: Set<String> = []
            for child in subfolders(url) {
                if isProjectRoot(child) {
                    found.insert(child.lastPathComponent)
                } else {
                    for grandchild in subfolders(child) where isProjectRoot(grandchild) {
                        found.insert(grandchild.lastPathComponent)
                    }
                }
            }
            inside[url.path] = found
            return found
        }

        private func subfolders(_ url: URL) -> [URL] {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles])) ?? []
            return children.filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
        }
    }

    private static func isProjectRoot(_ folder: URL) -> Bool {
        let fm = FileManager.default
        if rootFiles.contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) { return true }
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { rootExtensions.contains(($0 as NSString).pathExtension) }
    }
}
