/* Secrets aren't part of wrangler.toml, so `wrangler types` can't emit them —
 * merged into the generated Env interface here. */
interface Env {
  /** HMAC key for auth tokens — set via `wrangler secret put AUTH_SECRET`. Must be ≥32 chars. */
  AUTH_SECRET: string;
  /** Comma-separated origins allowed to call the API. Unset = allow any (token auth, no cookies). */
  ALLOWED_ORIGINS?: string;
  /** Public URL of the app, used to build password-reset links. */
  APP_URL?: string;
  /** Resend API key — enables password-reset emails. Without it, reset links can't be delivered. */
  RESEND_API_KEY?: string;
  /** From address for reset emails, e.g. "Bookshelf <no-reply@example.com>". */
  RESET_FROM?: string;
  /** LOCAL DEV ONLY: "1" returns the reset link in the API response. Never set in production. */
  RESET_DEBUG?: string;
  /**
   * Comma-separated user ids allowed to read and action the moderation queue.
   * Unset means nobody can — the queue is simply unavailable, which is the safe
   * default: reports still accumulate and auto-hide still fires without it.
   */
  ADMIN_UIDS?: string;
}
