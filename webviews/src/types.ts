import type { DiffViewerAppearance } from "./appearance";

export type DiffViewerPayload = {
  appearance?: DiffViewerAppearance;
  externalURL?: string;
  /** Repo-root-relative file scrolled into view once on first render. */
  initialFile?: string;
  labels?: Record<string, string>;
  layout?: "split" | "unified";
  layoutSource?: "default" | "explicit";
  pendingReplacement?: boolean;
  statusMessage?: string;
  title?: string;
  [key: string]: any;
};

export type DiffViewerConfig = {
  assets?: Record<string, string | undefined>;
  payload?: DiffViewerPayload;
  [key: string]: any;
};
