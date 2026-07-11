/* Shared data-model types for Enkela's Bookshelf.
 * The runtime source of truth is normalize() in app.ts — every Book field
 * listed there (its rebuild whitelist) must exist here, and vice versa.
 * Imported with `import type`, so this module is erased from emitted JS. */

export type BookStatus = "want" | "reading" | "finished" | "dnf";
export type BookFormat = "physical" | "ebook" | "audio";

export interface ReadingLog {
  id: string;
  date: string; // ISO timestamp
  pages: number; // per-session delta (input asks for current page; delta is stored)
  minutes: number; // audio/timer sessions
  mood: string;
  note: string;
}

export interface Quote {
  id: string;
  text: string;
  page: number | null;
  at: string | null;
}

export interface FinishRecord {
  date: string | null;
  rating: number | null;
}

export interface JournalEntry {
  id: string;
  date: string;
  page: number | null;
  text: string;
}

export interface BookCharacter {
  id: string;
  name: string;
  desc: string;
}

export interface VocabEntry {
  id: string;
  word: string;
  def: string;
  page: number | null;
}

export interface Bookmark {
  page: number | null;
  note: string;
  date: string | null;
}

/** One book, exactly as normalize() rebuilds it on every load/sync/import. */
export interface Book {
  id: string;
  title: string;
  author: string;
  totalPages: number;
  coverUrl: string;
  isbn: string;
  review: string;
  description: string;
  tags: string[];
  collections: string[];
  format: BookFormat;
  seriesName: string;
  seriesNumber: number | null;
  publishedYear: number | null;
  quotes: Quote[];
  readCount: number;
  finishHistory: FinishRecord[];
  journal: JournalEntry[];
  characters: BookCharacter[];
  vocab: VocabEntry[];
  bookmark: Bookmark | null;
  dnfReason: string;
  pickReason: string;
  expectation: number | null;
  loanDue: string;
  owned: boolean;
  location: string;
  coverTriedAt: string | null;
  lentTo: string;
  lentAt: string | null;
  status: BookStatus;
  rating: number | null;
  startedAt: string | null;
  finishedAt: string | null;
  addedAt: string;
  logs: ReadingLog[];
}

export interface GoalSettings {
  year: number;
  target: number;
  pagesTarget: number;
  dailyPages: number;
}

export interface AppState {
  version: number;
  updatedAt: string;
  settings: { goal: GoalSettings };
  shelfOrder: string[];
  books: Book[];
}

// --- Account / sync ----------------------------------------------------------

export interface AuthUser {
  email: string;
  fullName: string;
}

export interface Auth {
  token: string;
  user: AuthUser;
}

export type SyncStatus = "idle" | "syncing" | "offline" | "error" | "needslogin";

// --- Open Library search docs (auto-fetch / cover waterfall) ------------------

export interface OLDoc {
  key?: string;
  title?: string;
  author_name?: string[];
  first_publish_year?: number;
  number_of_pages_median?: number;
  cover_i?: number;
  isbn?: string[];
  subject?: string[];
}

// --- Chart data ---------------------------------------------------------------

export interface ChartItem {
  full: string;
  value: number;
  tick: string;
}

// --- Community recommendations (worker /api/recs) -----------------------------
// Field names mirror the D1 columns the worker returns verbatim.

export interface RecRow {
  id: string;
  book_title: string;
  book_author: string;
  book_isbn: string;
  category: string;
  cover_url: string;
  note: string;
  created_by?: string;
  created_name?: string;
  created_at?: string;
  up: number;
  down: number;
  /** 1 / -1 / 0 — this account's vote. */
  myVote?: number;
  /** True when the signed-in user posted this rec. */
  mine?: boolean | number;
  /// Client-side computed sort key (drawCommunity).
  score?: number;
}

// --- Reading clubs (worker /api/clubs) ----------------------------------------

export interface ClubMember {
  uid: string;
  display_name: string;
  role: string;
  progress_pct: number;
}

export interface ClubComment {
  id: string;
  display_name: string;
  body: string;
  pos_pct: number;
  label?: string;
  reactions?: { counts: Record<string, number>; mine: string[] };
}

export interface Club {
  id: string;
  /** Present on the clubs-list payload. */
  members?: ClubMember[];
  me?: { uid?: string; progress_pct?: number };
  code?: string;
  book_title?: string;
  book_author?: string;
  member_count?: number;
  last_activity?: string;
  created_by?: string;
}
