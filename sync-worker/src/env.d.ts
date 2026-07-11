/* Secrets aren't part of wrangler.toml, so `wrangler types` can't emit them —
 * merged into the generated Env interface here. */
interface Env {
  /** HMAC key for auth tokens — set via `wrangler secret put AUTH_SECRET`. */
  AUTH_SECRET: string;
}
