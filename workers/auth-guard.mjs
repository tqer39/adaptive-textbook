import { hash, encode } from "./crypto.mjs";
export const randomToken = () =>
  encode(crypto.getRandomValues(new Uint8Array(32)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
export const browserCookie = "__Host-textbook-browser";
export const cookieValue = (request) => {
  const v = (request.headers.get("Cookie") ?? "")
    .split(";")
    .map((s) => s.trim())
    .filter((s) => s.startsWith(browserCookie + "="));
  return v.length === 1 &&
    /^[A-Za-z0-9_-]{43}$/.test(v[0].slice(browserCookie.length + 1))
    ? v[0].slice(browserCookie.length + 1)
    : null;
};
export const browserHeader = (value) =>
  `${browserCookie}=${value}; Path=/; Max-Age=3600; HttpOnly; Secure; SameSite=Lax`;
export class AuthGuard {
  constructor(db, now = () => Date.now()) {
    this.db = db;
    this.now = now;
  }
  async context(id) {
    const now = this.now(),
      csrf = randomToken();
    return this.db
      .prepare(
        `INSERT INTO app_auth_browser(id,csrf,epoch,expires,window,starts) VALUES(?,?,1,?,0,0) ON CONFLICT(id) DO UPDATE SET csrf=CASE WHEN expires<=? THEN excluded.csrf ELSE csrf END,epoch=CASE WHEN expires<=? THEN epoch+1 ELSE epoch END,expires=CASE WHEN expires<=? THEN excluded.expires ELSE expires END RETURNING *`,
      )
      .bind(id, csrf, now + 3600000, now, now, now)
      .first();
  }
  async advance(id, csrf, starting = false) {
    const now = this.now();
    const c = await this.db
      .prepare(
        `UPDATE app_auth_browser SET epoch=epoch+1,window=CASE WHEN window<=? THEN ? ELSE window END,starts=CASE WHEN window<=? THEN ? ELSE starts+? END WHERE id=? AND csrf=? AND expires>? AND (?=0 OR window<=? OR starts<20) RETURNING *`,
      )
      .bind(
        now - 60000,
        now,
        now - 60000,
        starting ? 1 : 0,
        starting ? 1 : 0,
        id,
        csrf,
        now,
        starting ? 1 : 0,
        now - 60000,
      )
      .first();
    if (!c) throw Error("forbidden");
    await this.db.batch([
      this.db
        .prepare("DELETE FROM session WHERE appBrowser=? AND appEpoch<>?")
        .bind(id, c.epoch),
      this.db
        .prepare(
          "UPDATE app_auth_attempt SET status=? WHERE browser=? AND epoch<>?",
        )
        .bind("cancelled", id, c.epoch),
    ]);
    return c;
  }
  async issued(state, browser, epoch) {
    const digest = await hash(state);
    await this.db
      .prepare(
        "INSERT INTO app_auth_attempt(state,browser,epoch,status,expires) VALUES(?,?,?,?,?)",
      )
      .bind(digest, browser, epoch, "issued", this.now() + 600000)
      .run();
    return digest;
  }
  async claim(state, browser) {
    return this.db
      .prepare(
        `UPDATE app_auth_attempt SET status='claimed' WHERE state=? AND browser=? AND status='issued' AND expires>? AND epoch=(SELECT epoch FROM app_auth_browser WHERE id=? AND expires>?) RETURNING *`,
      )
      .bind(await hash(state), browser, this.now(), browser, this.now())
      .first();
  }
  async active(attempt) {
    if (!attempt) return false;
    return !!(await this.db
      .prepare(
        `SELECT 1 FROM app_auth_attempt a JOIN app_auth_browser b ON b.id=a.browser WHERE a.state=? AND a.status='claimed' AND a.expires>? AND b.expires>? AND a.epoch=b.epoch`,
      )
      .bind(attempt.state, this.now(), this.now())
      .first());
  }
  async complete(attempt) {
    return this.db
      .prepare(
        `UPDATE app_auth_attempt SET status='complete' WHERE state=? AND status='claimed' AND expires>? AND epoch=(SELECT epoch FROM app_auth_browser WHERE id=browser AND expires>?) RETURNING *`,
      )
      .bind(attempt.state, this.now(), this.now())
      .first();
  }
  async sessionValid(session, browser) {
    return !!(await this.db
      .prepare(
        "SELECT 1 FROM app_auth_browser WHERE id=? AND id=? AND epoch=? AND expires>?",
      )
      .bind(
        browser,
        session.appBrowser ?? "",
        session.appEpoch ?? -1,
        this.now(),
      )
      .first());
  }
  async cleanup() {
    const now = this.now();
    await this.db.batch([
      this.db
        .prepare(
          "DELETE FROM session WHERE expiresAt<=? OR appBrowser IN (SELECT id FROM app_auth_browser WHERE expires<=?)",
        )
        .bind(now, now),
      this.db
        .prepare("DELETE FROM app_auth_attempt WHERE expires<=?")
        .bind(now),
      this.db
        .prepare("DELETE FROM app_auth_browser WHERE expires<=?")
        .bind(now),
    ]);
  }
}
