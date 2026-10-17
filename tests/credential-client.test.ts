import { it, expect } from "vitest";
import { CredentialClient } from "../src/credential-client";
const setting = {
  revision: 1,
  model: "gpt-6-luna",
  state: "registered",
  checked: false,
  connection: "unconnected",
};
const data = {
  requestId: "local-test",
  expectedRevision: 0,
  model: "gpt-6-luna",
  key: "DUMMY-NOT-A-CREDENTIAL",
};
it("credential client remains locked on current production response and never sends key mutations", async () => {
  let calls = 0;
  const client = new CredentialClient(async () => {
    calls++;
    return new Response(
      JSON.stringify({
        status: "auth-unconfigured",
        realKeyInputEnabled: false,
      }),
      { status: 503 },
    );
  });
  expect(await client.session()).toEqual({ realKeyInputEnabled: false });
  expect(await client.register("openai", data)).toEqual({
    status: "unconnected",
  });
  expect(await client.replace("openai", data)).toEqual({
    status: "unconnected",
  });
  expect(await client.remove("openai", data)).toEqual({
    status: "unconnected",
  });
  expect(calls).toBe(1);
});
it("explicit test handshake exercises prepared API methods without retaining or returning dummy keys", async () => {
  const sent: RequestInit[] = [];
  const client = new CredentialClient(async (path, init) => {
    sent.push(init!);
    return new Response(
      JSON.stringify(
        path === "/api/session"
          ? {
              csrfToken: "dummy-csrf-token-with-no-live-grant",
              realKeyInputEnabled: true,
              connection: "unconnected",
            }
          : setting,
      ),
    );
  });
  expect(await client.session()).toEqual({ realKeyInputEnabled: true });
  const result = await client.register("openai", data);
  expect(result).toEqual({ status: "metadata", setting });
  expect(JSON.stringify(result)).not.toContain(data.key);
  expect(sent[1].redirect).toBe("error");
  expect(sent[1].credentials).toBe("same-origin");
  expect(JSON.parse(sent[1].body as string).key).toBe(data.key);
  expect(JSON.stringify(client)).not.toContain(data.key);
  client.lock();
  expect(await client.replace("openai", data)).toEqual({
    status: "unconnected",
  });
  expect(sent.length).toBe(2);
});
it("unexpected secret responses or network errors produce generic held with no retry or key echo", async () => {
  let calls = 0;
  const client = new CredentialClient(async (path) => {
    calls++;
    if (path === "/api/session")
      return new Response(
        JSON.stringify({
          csrfToken: "dummy-csrf-token-with-no-live-grant",
          realKeyInputEnabled: true,
          connection: "unconnected",
        }),
      );
    return new Response(JSON.stringify({ ...setting, secret: data.key }));
  });
  await client.session();
  expect(await client.register("openai", data)).toEqual({ status: "held" });
  expect(calls).toBe(2);
});
