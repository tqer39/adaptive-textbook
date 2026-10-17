import { it, expect } from "vitest";
import { AuthClient } from "../src/auth-client";
const status = {
  available: true,
  authenticated: false,
  csrfToken: "dummy-csrf-never-live-token",
  realKeyInputEnabled: false,
};
it("auth client is fail closed and does not start login without verified status", async () => {
  let calls = 0;
  const c = new AuthClient(async () => {
    calls++;
    return new Response("{}", { status: 503 });
  });
  expect(await c.status()).toEqual({ available: false, authenticated: false });
  expect(await c.start()).toBeNull();
  expect(calls).toBe(1);
});
it("login is CSRF-protected and permits only the fixed Google redirect", async () => {
  const sent: RequestInit[] = [];
  const c = new AuthClient(async (path, init) => {
    sent.push(init!);
    return new Response(
      JSON.stringify(
        path === "/api/auth/status"
          ? status
          : {
              authorizationUrl:
                "https://accounts.google.com/o/oauth2/v2/auth?state=dummy",
            },
      ),
    );
  });
  await c.status();
  expect(await c.start()).toContain("https://accounts.google.com/");
  expect(sent[1].headers).toMatchObject({ "X-CSRF-Token": status.csrfToken });
  expect(sent[1].redirect).toBe("error");
  expect(sent[1].body).toBe("{}");
});
it("malicious redirect and session permission to input a real key are rejected", async () => {
  for (const url of [
    "https://evil.test/login",
    "https://accounts.google.com@evil.test/login",
    "https://accounts.google.com/other",
  ]) {
    const c = new AuthClient(
      async (path) =>
        new Response(
          JSON.stringify(
            path === "/api/auth/status" ? status : { authorizationUrl: url },
          ),
        ),
    );
    await c.status();
    expect(await c.start()).toBeNull();
  }
  const c = new AuthClient(
    async () =>
      new Response(JSON.stringify({ ...status, realKeyInputEnabled: true })),
  );
  expect((await c.status()).available).toBe(false);
});
it("cancel invalidates a late login-start result and logout drops client CSRF without storing grants", async () => {
  let release: (r: Response) => void = () => {};
  const c = new AuthClient(async (path) => {
    if (path === "/api/auth/start")
      return new Promise<Response>((r) => {
        release = r;
      });
    return new Response(
      JSON.stringify(
        path === "/api/auth/status" ? status : { status: "signed-out" },
      ),
    );
  });
  await c.status();
  const start = c.start();
  expect(await c.cancel()).toBe(true);
  release(
    new Response(
      JSON.stringify({
        authorizationUrl: "https://accounts.google.com/o/oauth2/v2/auth",
      }),
    ),
  );
  expect(await start).toBeNull();
  await c.status();
  expect(await c.logout()).toBe(true);
  expect(await c.start()).toBeNull();
  expect(JSON.stringify(c)).not.toContain(status.csrfToken);
});
