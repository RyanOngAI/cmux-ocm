// swift-tools-version: 6.0

import PackageDescription

// CmuxCodeHighlighting isolates the (pre-1.0, fast-moving) tree-sitter + Neon
// dependencies behind a single boundary so their API churn never reaches the
// cmux app target. See docs/plans/2026-06-24-001-feat-treesitter-syntax-highlighting-plan.md (U1/U2).
//
// NOTE: This is the U1 validation slice — Python grammar only — used to confirm
// the tree-sitter C grammars build and link on this toolchain (Xcode 26.x /
// SwiftPM C-module regression, tree-sitter#5523) before expanding to TS/TSX/JS.
let package = Package(
    name: "CmuxCodeHighlighting",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCodeHighlighting",
            targets: ["CmuxCodeHighlighting"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/Neon", exact: "0.6.0"),
        // Must match the SwiftTreeSitter repo URL that Neon and the grammar packages
        // use (both pin github.com/ChimeHQ/SwiftTreeSitter). Using the newer
        // tree-sitter/swift-tree-sitter URL introduces a second package identity that
        // exposes the same SwiftTreeSitter target, which SPM rejects as a duplicate.
        //
        // Pinned to EXACTLY 0.8.0. Neon 0.6.0 calls ResolvingQueryCursor.init(cursor:)
        // synchronously; SwiftTreeSitter 0.9.0+ added a @MainActor-isolated overload of
        // that initializer, which makes Neon fail to compile. 0.8.0 has no @MainActor
        // overload, and it is also the floor required by the tree-sitter grammar
        // packages (from: 0.8.0) — so 0.8.0 is the one version that satisfies the whole
        // graph. Upgrading SwiftTreeSitter requires also upgrading Neon (its `main`
        // tracks SwiftTreeSitter `main`); revisit together. See the U1 notes in the plan.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.8.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        // tree-sitter-typescript's single product bundles two modules:
        // TreeSitterTypeScript (tree_sitter_typescript) and TreeSitterTSX (tree_sitter_tsx).
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        // tree-sitter-javascript covers both JavaScript and JSX (tree_sitter_javascript).
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
    ],
    targets: [
        .target(
            name: "CmuxCodeHighlighting",
            dependencies: [
                .product(name: "Neon", package: "Neon"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
            ]
        ),
        .testTarget(
            name: "CmuxCodeHighlightingTests",
            dependencies: ["CmuxCodeHighlighting"]
        ),
    ]
)
