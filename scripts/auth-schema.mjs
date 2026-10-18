// Compile migration locally using a temporary Miniflare D1; never create a cloud resource.
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { getMigrations } from "better-auth/db/migration";
import { writeFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { authOptions } from "../workers/better-auth.mjs";
const dir = await mkdtemp(join(tmpdir(), "textbook-schema-"));
const mf = new Miniflare(
  convertV4MiniflareOptions({
    modules: true,
    script: 'export default {fetch(){return new Response("off")}}',
    d1Databases: { AUTH_DB: "test-auth" },
    resourcePersistencePath: dir,
    outboundService: () => {
      throw Error("offline");
    },
  }),
);
try {
  const db = await mf.getD1Database("AUTH_DB");
  const m = await getMigrations(
    authOptions({
      AUTH_DB: db,
      APP_ORIGIN: "https://app.test",
      BETTER_AUTH_SECRET: "DUMMY-MIGRATION-ONLY-" + crypto.randomUUID(),
      GOOGLE_CLIENT_ID: "dummy.apps.googleusercontent.com",
      GOOGLE_CLIENT_SECRET: "DUMMY-UNUSED",
    }),
  );
  await writeFile(
    "migrations/auth/0001_better_auth.sql",
    (await m.compileMigrations()) + "\n",
  );
} finally {
  await mf.dispose();
  await rm(dir, { recursive: true, force: true });
}
