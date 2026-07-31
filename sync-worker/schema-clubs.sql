-- Enkela's Bookshelf — Reading Clubs (Cloudflare D1 / SQLite)
-- Apply to production with:
--   wrangler d1 execute enkelas-clubs --remote --file sync-worker/schema-clubs.sql
--
-- To seed the LOCAL dev DB, you must pass --config as well, from sync-worker/:
--   cd sync-worker && npx wrangler d1 execute enkelas-clubs --local --config wrangler.toml --file schema-clubs.sql
-- Without --config, wrangler resolves the ROOT wrangler.jsonc and writes to
-- ./.wrangler/state, while `wrangler dev --config wrangler.toml` reads
-- sync-worker/.wrangler/state — two different SQLite files. Seeding the wrong
-- one makes every clubs/recs endpoint answer "no such table: clubs" (a 500),
-- which reads as nine broken tests rather than an unseeded database.

CREATE TABLE IF NOT EXISTS clubs (
  id          TEXT PRIMARY KEY,             -- uuid
  host_uid    TEXT NOT NULL,
  book_title  TEXT NOT NULL,
  book_author TEXT,
  book_isbn   TEXT,
  total_pages INTEGER,                       -- informational (for % display)
  created_at  TEXT NOT NULL,
  archived    INTEGER NOT NULL DEFAULT 0,
  last_activity TEXT                          -- ISO of the last comment/reaction (unread dots)
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
-- "which clubs am I in?" filters on uid alone, which the (club_id, uid) primary
-- key can't serve — that was a full table scan on every clubs-list request.
CREATE INDEX IF NOT EXISTS idx_members_uid ON members(uid);
-- idx_members_club duplicated the primary key's leading column: it could never
-- be chosen over the PK, and cost a write on every membership change.
DROP INDEX IF EXISTS idx_members_club;

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

-- Community recommendations -------------------------------------------------
-- A single shared, public board: any reader can recommend a book under a
-- category (genre), and everyone votes whether it's worth reading. Unlike
-- clubs there is no spoiler gate and no membership — the board is global.
CREATE TABLE IF NOT EXISTS recs (
  id           TEXT PRIMARY KEY,             -- uuid
  category     TEXT NOT NULL,                -- genre/category label (grouping key)
  book_title   TEXT NOT NULL,
  book_author  TEXT,
  book_isbn    TEXT,
  cover_url    TEXT,
  note         TEXT,                          -- optional "why read it"
  created_by   TEXT NOT NULL,                -- uid of the recommender
  created_name TEXT,                          -- display name at time of rec
  created_at   TEXT NOT NULL,
  deleted      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_recs_category ON recs(category);

-- One vote per user per recommendation: 1 = worth reading, -1 = not worth it.
CREATE TABLE IF NOT EXISTS rec_votes (
  rec_id     TEXT NOT NULL,
  uid        TEXT NOT NULL,
  vote       INTEGER NOT NULL,               -- 1 | -1
  created_at TEXT NOT NULL,
  PRIMARY KEY (rec_id, uid)
);
CREATE INDEX IF NOT EXISTS idx_rec_votes_rec ON rec_votes(rec_id);
-- "how did I vote?" filters on uid alone — again unreachable via the
-- (rec_id, uid) primary key, so it scanned every vote ever cast.
CREATE INDEX IF NOT EXISTS idx_rec_votes_uid ON rec_votes(uid);
-- The board is paged by recency, so give the ORDER BY an index to walk.
CREATE INDEX IF NOT EXISTS idx_recs_created ON recs(created_at DESC);
