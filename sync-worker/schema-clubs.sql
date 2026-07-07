-- Enkela's Bookshelf — Reading Clubs (Cloudflare D1 / SQLite)
-- Apply with:  wrangler d1 execute enkelas-clubs --remote --file sync-worker/schema-clubs.sql
-- (drop --remote to seed the local dev DB instead)

CREATE TABLE IF NOT EXISTS clubs (
  id          TEXT PRIMARY KEY,             -- uuid
  host_uid    TEXT NOT NULL,
  book_title  TEXT NOT NULL,
  book_author TEXT,
  book_isbn   TEXT,
  total_pages INTEGER,                       -- informational (for % display)
  created_at  TEXT NOT NULL,
  archived    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS members (
  club_id      TEXT NOT NULL,
  uid          TEXT NOT NULL,
  display_name TEXT,
  role         TEXT NOT NULL DEFAULT 'member',  -- 'host' | 'member'
  progress_pct INTEGER NOT NULL DEFAULT 0,      -- 0..100 — THE spoiler-gate key
  joined_at    TEXT NOT NULL,
  PRIMARY KEY (club_id, uid)
);
CREATE INDEX IF NOT EXISTS idx_members_club ON members(club_id);

CREATE TABLE IF NOT EXISTS invites (
  code       TEXT PRIMARY KEY,               -- short join code
  club_id    TEXT NOT NULL,
  created_by TEXT NOT NULL,
  expires_at TEXT,
  max_uses   INTEGER NOT NULL DEFAULT 6,
  uses       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_invites_club ON invites(club_id);

CREATE TABLE IF NOT EXISTS comments (
  id         TEXT PRIMARY KEY,
  club_id    TEXT NOT NULL,
  uid        TEXT NOT NULL,
  pos_pct    INTEGER NOT NULL,               -- 0..100 — the gate
  chapter    INTEGER,                         -- optional (ePub-linked) for threading
  label      TEXT,                            -- optional human label
  body       TEXT NOT NULL,
  created_at TEXT NOT NULL,
  deleted    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_comments_gate ON comments(club_id, pos_pct);

-- Reactions attach to a comment; they inherit that comment's spoiler gate.
CREATE TABLE IF NOT EXISTS reactions (
  comment_id TEXT NOT NULL,
  uid        TEXT NOT NULL,
  emoji      TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (comment_id, uid, emoji)
);
CREATE INDEX IF NOT EXISTS idx_reactions_comment ON reactions(comment_id);
