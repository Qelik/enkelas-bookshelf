/* Ambient declarations for browser APIs that lib.dom doesn't ship yet, the
 * vendored JSZip global, and the window hooks this app deliberately exposes
 * (tests.html harness + console debugging). This file has no imports/exports,
 * so everything here is global to the whole program. */

// --- Vendored JSZip (classic script tag, loaded before the module graph) ----

interface JSZipObject {
  name: string;
  dir: boolean;
  async(type: "string"): Promise<string>;
  async(type: "arraybuffer"): Promise<ArrayBuffer>;
  async(type: "blob"): Promise<Blob>;
  async(type: "base64"): Promise<string>;
}

interface JSZipArchive {
  files: Record<string, JSZipObject>;
  file(path: string): JSZipObject | null;
  forEach(cb: (relativePath: string, entry: JSZipObject) => void): void;
}

interface JSZipStatic {
  loadAsync(data: ArrayBuffer | Uint8Array | Blob): Promise<JSZipArchive>;
}

declare var JSZip: JSZipStatic | undefined;

// --- Barcode Detection API (Chrome/Android; absent on iOS Safari) -----------

interface DetectedBarcode {
  rawValue: string;
  format: string;
  boundingBox: DOMRectReadOnly;
  cornerPoints: ReadonlyArray<{ x: number; y: number }>;
}

declare class BarcodeDetector {
  constructor(options?: { formats?: string[] });
  static getSupportedFormats(): Promise<string[]>;
  detect(source: ImageBitmapSource): Promise<DetectedBarcode[]>;
}

// --- File System Access API (desktop Chrome/Edge only) ----------------------

interface FilePickerAcceptType {
  description?: string;
  accept: Record<string, string | string[]>;
}

interface OpenFilePickerOptions {
  types?: FilePickerAcceptType[];
  excludeAcceptAllOption?: boolean;
  multiple?: boolean;
}

interface SaveFilePickerOptions {
  suggestedName?: string;
  types?: FilePickerAcceptType[];
}

// --- PWA install prompt ------------------------------------------------------

interface BeforeInstallPromptEvent extends Event {
  prompt(): Promise<void>;
  readonly userChoice: Promise<{ outcome: "accepted" | "dismissed"; platform: string }>;
}

interface WindowEventMap {
  beforeinstallprompt: BeforeInstallPromptEvent;
}

// --- Window surface this app exposes/consumes --------------------------------
// Loosely typed during the migration; tightened as src/types.ts fills in.

interface Window {
  showOpenFilePicker?(options?: OpenFilePickerOptions): Promise<FileSystemFileHandle[]>;
  showSaveFilePicker?(options?: SaveFilePickerOptions): Promise<FileSystemFileHandle>;

  /** Vendored classic script; also reachable as the bare global `JSZip`. */
  JSZip?: JSZipStatic;

  /** Public API app.ts exports and mirrors here for console/backwards-compat. */
  BookshelfAPI?: unknown;
  /** Reader API reader.ts exports and mirrors here for console/backwards-compat. */
  EReader?: unknown;

  // Test/debug hooks (tests.html harness — keep these working).
  __test?: Record<string, Function>;
  __authorMatches?: Function;
  __checkScannedBook?: Function;
  __decodeEAN13Canvas?: Function;
  __readerBuild?: string;
}
