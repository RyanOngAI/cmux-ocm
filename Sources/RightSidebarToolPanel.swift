import AppKit
import Combine
import SwiftUI

@MainActor
final class RightSidebarToolPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .rightSidebarTool
    let mode: RightSidebarMode

    @Published private(set) var focusFlashToken: Int = 0

    private weak var workspace: Workspace?
    private weak var fileExplorerContainerView: FileExplorerContainerView?
    private weak var sessionIndexFocusAnchorView: RightSidebarToolFocusAnchorView?
    private weak var changesFocusAnchorView: RightSidebarToolFocusAnchorView?
    private var fileExplorerStoreStorage: FileExplorerStore?
    private var fileExplorerStateStorage: FileExplorerState?
    private var sessionIndexStoreStorage: SessionIndexStore?
    /// Registry-owned Changes store attached while this pane is open
    /// (`.changes` mode only). Attach in `reattach(to:)`, detach in `close()`.
    /// Published so the hosted view re-resolves after cross-window reattach.
    @Published private(set) var gitChangesStoreStorage: GitChangesStore?
    private var gitChangesAttachedWorkspaceId: UUID?
    /// The exact TabManager the current registration was made against; detach
    /// must decrement THIS manager's registry — after a cross-window workspace
    /// move, resolving by workspace id would target the destination manager
    /// and corrupt a registration it never made.
    private weak var gitChangesAttachedTabManager: TabManager?
    private var workspaceObservationCancellable: AnyCancellable?

    init(workspace: Workspace, mode: RightSidebarMode) {
        self.id = UUID()
        self.mode = mode
        reattach(to: workspace)
    }

    deinit {
        // Explicit no-op so future teardown has a single home.
    }

    var fileExplorerStore: FileExplorerStore {
        if let store = fileExplorerStoreStorage { return store }
        let store = FileExplorerStore()
        store.showHiddenFiles = true
        fileExplorerStoreStorage = store
        if let workspace {
            syncFileExplorerRoot(from: workspace, store: store)
        }
        return store
    }

    var fileExplorerState: FileExplorerState {
        if let state = fileExplorerStateStorage { return state }
        let state = FileExplorerState()
        fileExplorerStateStorage = state
        return state
    }

    var sessionIndexStore: SessionIndexStore {
        if let store = sessionIndexStoreStorage { return store }
        let store = SessionIndexStore()
        sessionIndexStoreStorage = store
        if let workspace {
            syncSessionIndexRoot(from: workspace, store: store)
        }
        return store
    }

    var displayTitle: String { mode.label }
    var displayIcon: String? { mode.symbolName }

    /// Workspace this pane is attached to; the Changes row-click handler uses
    /// it to target the branch diff viewer launch.
    var changesWorkspaceId: UUID? { workspace?.id }

    /// Workspace reference for the Changes PR header (observed at the hosted
    /// panel's root for PR metadata, CI check state, and agent presence).
    var changesWorkspace: Workspace? { workspace }

    func reattach(to workspace: Workspace) {
        self.workspace = workspace
        if mode == .changes {
            attachGitChangesObserver(to: workspace)
        }
        observeWorkspaceRootChanges(workspace)
        syncWorkspaceRoot(from: workspace)
    }

    func attachFileExplorerContainer(_ container: FileExplorerContainerView?) {
        fileExplorerContainerView = container
    }

    fileprivate func attachSessionIndexFocusAnchor(_ anchor: RightSidebarToolFocusAnchorView?) {
        sessionIndexFocusAnchorView = anchor
    }

    fileprivate func attachChangesFocusAnchor(_ anchor: RightSidebarToolFocusAnchorView?) {
        changesFocusAnchorView = anchor
    }

    func syncWorkspaceRoot(from workspace: Workspace) {
        switch mode {
        case .files, .find:
            guard let store = fileExplorerStoreStorage else { return }
            syncFileExplorerRoot(from: workspace, store: store)
        case .changes:
            // Re-runs the attach so manager drift (workspace moved windows
            // without a reattach) re-homes the registration; the same-manager
            // case reduces to a root update on the registry-owned store.
            attachGitChangesObserver(to: workspace)
        case .sessions:
            guard let store = sessionIndexStoreStorage else { return }
            syncSessionIndexRoot(from: workspace, store: store)
        case .feed, .dock:
            break
        }
    }

    /// Attaches this pane as one visible observer of the workspace's Changes
    /// store, releasing any registration held against a previous workspace or
    /// a previous TabManager (cross-window surface transfer re-runs
    /// `reattach(to:)`; a workspace moved between windows resolves to a new
    /// manager even with the same workspace id).
    private func attachGitChangesObserver(to workspace: Workspace) {
        let manager = resolvedTabManager(for: workspace)
        if gitChangesAttachedWorkspaceId == workspace.id,
           let manager, manager === gitChangesAttachedTabManager {
            gitChangesStoreStorage?.setWorkspaceRoot(.forWorkspace(workspace))
            return
        }
        detachGitChangesObserverIfNeeded()
        guard let manager else { return }
        gitChangesStoreStorage = manager.attachGitChangesObserver(
            workspaceId: workspace.id,
            root: .forWorkspace(workspace)
        )
        gitChangesAttachedWorkspaceId = workspace.id
        gitChangesAttachedTabManager = manager
    }

    private func detachGitChangesObserverIfNeeded() {
        guard let workspaceId = gitChangesAttachedWorkspaceId else { return }
        // Detach ALWAYS goes through the manager the attach was made against;
        // resolving by workspace id would target the destination manager
        // after a cross-window move (decrementing a registration it never
        // made and leaking the source's). Fallback chain only when the
        // recorded manager is gone.
        let manager = gitChangesAttachedTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
            ?? workspace.flatMap { resolvedTabManager(for: $0) }
            ?? AppDelegate.shared?.tabManager
        gitChangesAttachedWorkspaceId = nil
        gitChangesAttachedTabManager = nil
        gitChangesStoreStorage = nil
        manager?.detachGitChangesObserver(workspaceId: workspaceId)
    }

    private func resolvedTabManager(for workspace: Workspace) -> TabManager? {
        workspace.owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: workspace.id)
            ?? AppDelegate.shared?.tabManager
    }

    func openFilePreview(_ filePath: String) {
        guard let workspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }
        if workspace.isRemoteWorkspace {
            let store = fileExplorerStore
            Task { [weak workspace, weak store] in
                guard let workspace, let store else { return }
                do {
                    let localURL = try await store.materializeRemoteFileForPreview(path: filePath)
                    _ = workspace.openFileSurfaces(
                        inPane: paneId,
                        filePaths: [localURL.path],
                        focus: true,
                        reuseExisting: true
                    )
                } catch {
                    NSSound.beep()
                }
            }
            return
        }
        _ = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [filePath],
            focus: true,
            reuseExisting: true
        )
    }

    var isFocusedInWorkspace: Bool {
        workspace?.focusedPanelId == id
    }

    func close() {
        fileExplorerContainerView = nil
        sessionIndexFocusAnchorView = nil
        changesFocusAnchorView = nil
        fileExplorerStoreStorage?.applyWorkspaceRoot(.none)
        sessionIndexStoreStorage?.setCurrentDirectoryIfChanged(nil)
        detachGitChangesObserverIfNeeded()
        workspaceObservationCancellable = nil
    }

    func focus() {
        switch mode {
        case .files:
            _ = fileExplorerContainerView?.focusOutline()
        case .find:
            _ = fileExplorerContainerView?.focusSearchField()
        case .changes:
            guard let anchor = changesFocusAnchorView,
                  let window = anchor.window else { return }
            _ = window.makeFirstResponder(anchor)
        case .sessions:
            guard let anchor = sessionIndexFocusAnchorView,
                  let window = anchor.window else { return }
            _ = window.makeFirstResponder(anchor)
        case .feed, .dock:
            break
        }
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        switch mode {
        case .files, .find:
            guard fileExplorerContainerView?.ownsKeyboardFocus(responder) == true else { return nil }
            return .panel
        case .changes:
            guard changesFocusAnchorView?.ownsKeyboardFocus(responder) == true else { return nil }
            return .panel
        case .sessions:
            guard sessionIndexFocusAnchorView?.ownsKeyboardFocus(responder) == true else { return nil }
            return .panel
        case .feed, .dock:
            return nil
        }
    }

    private func observeWorkspaceRootChanges(_ workspace: Workspace) {
        workspaceObservationCancellable = Publishers.MergeMany(
            workspace.$currentDirectory.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteConfiguration.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteConnectionState.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteConnectionDetail.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteDaemonStatus.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self, weak workspace] _ in
            Task { @MainActor in
                guard let self, let workspace else { return }
                self.syncWorkspaceRoot(from: workspace)
            }
        }
    }

    private func syncFileExplorerRoot(from workspace: Workspace, store: FileExplorerStore) {
        store.showHiddenFiles = true

        if workspace.isRemoteWorkspace {
            guard let configuration = workspace.remoteConfiguration,
                  configuration.transport == .ssh else {
                store.applyWorkspaceRoot(.none)
                return
            }
            let unavailableDetail = workspace.remoteConnectionDetail ?? workspace.remoteDaemonStatus.detail
            store.applyWorkspaceRoot(
                .remoteSSH(
                    workspaceId: workspace.id,
                    connection: SSHFileExplorerConnection(
                        destination: configuration.destination,
                        port: configuration.port,
                        identityFile: configuration.identityFile,
                        sshOptions: configuration.sshOptions
                    ),
                    displayTarget: configuration.displayTarget,
                    rootPath: workspace.currentDirectory,
                    isAvailable: workspace.remoteConnectionState == .connected,
                    unavailableDetail: unavailableDetail
                )
            )
            return
        }

        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            store.applyWorkspaceRoot(.none)
            return
        }

        store.applyWorkspaceRoot(.local(path: directory))
    }

    private func syncSessionIndexRoot(from workspace: Workspace, store: SessionIndexStore) {
        guard !workspace.isRemoteWorkspace else {
            store.setCurrentDirectoryIfChanged(nil)
            return
        }

        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setCurrentDirectoryIfChanged(directory.isEmpty ? nil : directory)
    }
}

struct RightSidebarToolPanelView: View {
    @ObservedObject var panel: RightSidebarToolPanel
    @EnvironmentObject private var tabManager: TabManager
    let isFocused: Bool
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: appearance.backgroundColor))
            .overlay {
                WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
            }
            .simultaneousGesture(TapGesture().onEnded { requestPanelFocusIfNeeded() })
            .onChange(of: panel.focusFlashToken) { _, _ in
                triggerFocusFlashAnimation()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch panel.mode {
        case .files:
            FileExplorerPanelView(
                store: panel.fileExplorerStore,
                state: panel.fileExplorerState,
                onOpenFilePreview: panel.openFilePreview,
                presentation: .files,
                placement: .pane,
                onFocus: requestPanelFocusIfNeeded,
                onContainerChange: panel.attachFileExplorerContainer
            )
        case .find:
            FileExplorerPanelView(
                store: panel.fileExplorerStore,
                state: panel.fileExplorerState,
                onOpenFilePreview: panel.openFilePreview,
                presentation: .find,
                placement: .pane,
                onFocus: requestPanelFocusIfNeeded,
                onContainerChange: panel.attachFileExplorerContainer
            )
        case .changes:
            GitChangesPanelHostView(
                store: panel.gitChangesStoreStorage,
                workspace: panel.changesWorkspace,
                onOpenFile: { file in
                    guard let workspaceId = panel.changesWorkspaceId else { return }
                    AppDelegate.shared?.openBranchDiffViewer(
                        workspaceId: workspaceId,
                        filePath: file.path,
                        snapshot: panel.gitChangesStoreStorage?.snapshot
                    )
                }
            )
            .background(
                RightSidebarToolFocusAnchor(onViewChange: panel.attachChangesFocusAnchor)
                    .frame(width: 0, height: 0)
            )
        case .sessions:
            SessionIndexView(
                store: panel.sessionIndexStore,
                onResume: { entry in
                    SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
                }
            )
            .background(
                RightSidebarToolFocusAnchor(onViewChange: panel.attachSessionIndexFocusAnchor)
                    .frame(width: 0, height: 0)
            )
        case .feed, .dock:
            EmptyView()
        }
    }

    private func requestPanelFocusIfNeeded() {
        guard !panel.isFocusedInWorkspace else { return }
        onRequestPanelFocus()
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

private struct RightSidebarToolFocusAnchor: NSViewRepresentable {
    final class Coordinator {
        var onViewChange: (RightSidebarToolFocusAnchorView?) -> Void
        weak var attachedView: RightSidebarToolFocusAnchorView?

        init(onViewChange: @escaping (RightSidebarToolFocusAnchorView?) -> Void) {
            self.onViewChange = onViewChange
        }

        func attach(_ view: RightSidebarToolFocusAnchorView) {
            guard attachedView !== view else { return }
            attachedView = view
            onViewChange(view)
        }

        func detach(_ view: RightSidebarToolFocusAnchorView) {
            guard attachedView === view else { return }
            attachedView = nil
            onViewChange(nil)
        }
    }

    let onViewChange: (RightSidebarToolFocusAnchorView?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onViewChange: onViewChange)
    }

    func makeNSView(context: Context) -> RightSidebarToolFocusAnchorView {
        let view = RightSidebarToolFocusAnchorView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: RightSidebarToolFocusAnchorView, context: Context) {
        context.coordinator.onViewChange = onViewChange
        context.coordinator.attach(nsView)
    }

    static func dismantleNSView(_ nsView: RightSidebarToolFocusAnchorView, coordinator: Coordinator) {
        coordinator.detach(nsView)
    }
}

fileprivate final class RightSidebarToolFocusAnchorView: NSView {
    override var acceptsFirstResponder: Bool { true }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        guard let responderView = Self.view(for: responder) else { return false }
        guard let root = focusRootView else { return false }
        return responderView === root || responderView.isDescendant(of: root)
    }

    private static func view(for responder: NSResponder) -> NSView? {
        if let view = responder as? NSView {
            return view
        }
        if let textView = responder as? NSTextView,
           let delegateView = textView.delegate as? NSView {
            return delegateView
        }
        return nil
    }

    private var focusRootView: NSView? {
        guard let superview else { return nil }
        var current: NSView? = superview
        while let view = current {
            let typeName = String(describing: type(of: view))
            if typeName.contains("NSHosting") || typeName.contains("ViewHost") {
                return view
            }
            current = view.superview
        }
        return superview
    }
}
