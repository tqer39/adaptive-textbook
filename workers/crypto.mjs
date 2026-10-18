import { z } from "zod";
const encoder = new TextEncoder();
const ringSchema = z
  .object({
    active: z.string().regex(/^[a-z0-9-]{1,32}$/),
    keys: z.record(z.string().regex(/^[a-z0-9-]{1,32}$/), z.string().max(64)),
  })
  .strict();
const encryptedSchema = z
  .object({
    schema: z.literal(1),
    keyVersion: z.string().max(32),
    nonce: z.string().max(32),
    ciphertext: z.string().max(1024),
  })
  .strict();
export const bytes = (text) => encoder.encode(text);
export const encode = (data) =>
  btoa(String.fromCharCode(...new Uint8Array(data)));
export const decode = (text) =>
  Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
export async function hash(value) {
  return [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", bytes(JSON.stringify(value))),
    ),
  ]
    .map((n) => n.toString(16).padStart(2, "0"))
    .join("");
}
export function ring(value) {
  try {
    if (typeof value !== "string" || value.length > 2048) throw Error();
    const parsed = ringSchema.parse(JSON.parse(value));
    if (!parsed.keys[parsed.active] || Object.keys(parsed.keys).length > 4)
      throw Error();
    for (const key of Object.values(parsed.keys))
      if (decode(key).byteLength !== 32 || encode(decode(key)) !== key)
        throw Error();
    return parsed;
  } catch {
    throw Error("encryption-unconfigured");
  }
}
const aad = (owner, provider, revision, version) =>
  bytes(JSON.stringify({ schema: 1, owner, provider, revision, version }));
async function aes(raw) {
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
}
export async function encrypt(secret, owner, provider, revision, config) {
  const keys = ring(config);
  const version = keys.active;
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: nonce,
      additionalData: aad(owner, provider, revision, version),
      tagLength: 128,
    },
    await aes(decode(keys.keys[version])),
    bytes(secret),
  );
  return {
    schema: 1,
    keyVersion: version,
    nonce: encode(nonce),
    ciphertext: encode(ciphertext),
  };
}
export async function decrypt(value, owner, provider, revision, config) {
  const keys = ring(config);
  try {
    const blob = encryptedSchema.parse(value);
    const raw = keys.keys[blob.keyVersion];
    if (!raw || decode(blob.nonce).byteLength !== 12) throw Error();
    const result = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: decode(blob.nonce),
        additionalData: aad(owner, provider, revision, blob.keyVersion),
        tagLength: 128,
      },
      await aes(decode(raw)),
      decode(blob.ciphertext),
    );
    return new TextDecoder("utf-8", { fatal: true }).decode(result);
  } catch {
    throw Error("credential-unavailable");
  }
}
export async function fingerprint(value, config, version) {
  const keys = ring(config);
  const keyVersion = version ?? keys.active;
  if (!keys.keys[keyVersion]) throw Error("encryption-unconfigured");
  const root = await crypto.subtle.importKey(
    "raw",
    decode(keys.keys[keyVersion]),
    "HKDF",
    false,
    ["deriveKey"],
  );
  const key = await crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: bytes("adaptive-textbook-byok-v1"),
      info: bytes("idempotency-fingerprint"),
    },
    root,
    { name: "HMAC", hash: "SHA-256", length: 256 },
    false,
    ["sign"],
  );
  return {
    keyVersion,
    digest: encode(
      await crypto.subtle.sign("HMAC", key, bytes(JSON.stringify(value))),
    ),
  };
}
