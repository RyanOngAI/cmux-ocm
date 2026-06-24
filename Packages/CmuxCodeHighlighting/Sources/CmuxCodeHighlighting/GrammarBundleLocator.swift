import Foundation

/// Locates a tree-sitter grammar's bundled query files at runtime.
///
/// SwiftTreeSitter's built-in resolver assumes the embedded macOS *app* bundle layout
/// (`<name>.bundle/Contents/Resources/queries`). SwiftPM's `swift build`/`swift test`
/// produces a *flat* layout (`<name>.bundle/queries`), and the bundle can live next to
/// the executable rather than under `Bundle.main.resourceURL`. This locator searches
/// every plausible base directory and both layouts so query loading works identically
/// in the app, in XCTest, and under Swift Testing.
enum GrammarBundleLocator {
    /// Extra directories to search beyond the `Bundle`-derived ones. Empty in
    /// production (the app finds grammar bundles under `Bundle.main.resourceURL`).
    /// Tests set this to the SwiftPM build-products directory, which `Bundle.main`
    /// does not reach under `swift test` (the host is Xcode's testing helper).
    nonisolated(unsafe) static var additionalSearchDirectories: [URL] = []

    /// Return the `queries` directory inside `<bundleName>.bundle`, or `nil` if it
    /// cannot be found. A directory qualifies only if it contains `highlights.scm`.
    static func queriesDirectoryURL(forBundleNamed bundleName: String) -> URL? {
        let bundleFileName = "\(bundleName).bundle"
        let layoutSubpaths = ["queries", "Contents/Resources/queries"]

        for base in candidateBaseURLs() {
            let bundleURL = base.appendingPathComponent(bundleFileName, isDirectory: true)
            for subpath in layoutSubpaths {
                let queriesURL = bundleURL.appendingPathComponent(subpath, isDirectory: true)
                let highlights = queriesURL.appendingPathComponent("highlights.scm")
                if FileManager.default.fileExists(atPath: highlights.path) {
                    return queriesURL
                }
            }
        }
        return nil
    }

    /// Directories that may contain the grammar resource bundles, most-likely first.
    private static func candidateBaseURLs() -> [URL] {
        var bases: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL?) {
            guard let url else { return }
            if seen.insert(url.standardizedFileURL.path).inserted {
                bases.append(url)
            }
        }

        // App bundle: grammar bundles live under Bundle.main.resourceURL.
        add(Bundle.main.resourceURL)
        add(Bundle.main.bundleURL)
        // `swift test`/CLI: grammar bundles are siblings of the executable or the
        // .xctest bundle (i.e. the SwiftPM build-products directory), so also search
        // the parent of the main bundle and of the executable directory.
        add(Bundle.main.bundleURL.deletingLastPathComponent())
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            add(exeDir)
            add(exeDir.deletingLastPathComponent())
        }
        for bundle in Bundle.allBundles {
            add(bundle.resourceURL)
            add(bundle.bundleURL.deletingLastPathComponent())
        }
        for framework in Bundle.allFrameworks { add(framework.resourceURL) }
        for directory in additionalSearchDirectories { add(directory) }

        return bases
    }
}
