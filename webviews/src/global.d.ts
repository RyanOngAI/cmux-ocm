export {};

declare global {
  interface Window {
    __cmuxDiffViewer?: {
      codeView?: unknown;
      codeViewItems?: unknown[];
      items?: unknown[];
      state?: unknown;
      streamMetrics?: unknown;
      workerPool?: unknown;
    };
    /**
     * In-page jump fast path for the host app: scrolls the rendered diff to a
     * repo-root-relative file path without reloading the viewer. Returns true
     * when the file was found and scrolled.
     */
    cmuxDiffViewerScrollToFile?: (path: string) => boolean;
  }
}
