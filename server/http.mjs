import { createServer } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { limits, requestSchema } from "./contracts.mjs";

export function localServer({
  service,
  port = 5274,
  origin = "http://127.0.0.1:5173",
}) {
  if (origin !== "http://127.0.0.1:5173") throw Error("origin-invalid");
  const token = randomBytes(32).toString("hex");
  const server = createServer(async (req, res) => {
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Content-Type-Options", "nosniff");
    const send = (status, value) => {
      res.writeHead(status, {
        "Content-Type": "application/json; charset=utf-8",
      });
      res.end(JSON.stringify(value));
    };
    if (
      req.socket.remoteAddress !== "127.0.0.1" ||
      req.headers.host !== `127.0.0.1:${server.address().port}` ||
      req.headers.origin !== origin ||
      req.headers["x-forwarded-host"] ||
      req.headers["x-forwarded-for"] ||
      (req.headers["sec-fetch-site"] &&
        !["same-site", "same-origin"].includes(req.headers["sec-fetch-site"]))
    )
      return send(403, { status: "forbidden" });
    res.setHeader("Access-Control-Allow-Origin", origin);
    res.setHeader("Vary", "Origin");
    if (req.method === "OPTIONS" && req.url === "/proposals") {
      res.setHeader("Access-Control-Allow-Methods", "POST");
      res.setHeader(
        "Access-Control-Allow-Headers",
        "Content-Type, X-CSRF-Token",
      );
      res.writeHead(204);
      return res.end();
    }
    if (req.method === "GET" && req.url === "/session")
      return send(200, { status: "unconnected", csrfToken: token });
    if (req.method !== "POST" || req.url !== "/proposals")
      return send(404, { status: "not-found" });
    const supplied = req.headers["x-csrf-token"];
    if (
      typeof supplied !== "string" ||
      !/^[a-f0-9]{64}$/.test(supplied) ||
      !timingSafeEqual(Buffer.from(supplied), Buffer.from(token))
    )
      return send(403, { status: "forbidden" });
    if (req.headers["content-type"] !== "application/json")
      return send(415, { status: "json-required" });
    const length = Number(req.headers["content-length"]);
    if (length > limits.bodyBytes) return send(413, { status: "body-limit" });
    try {
      const chunks = [];
      let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > limits.bodyBytes) {
          send(413, { status: "body-limit" });
          return;
        }
        chunks.push(chunk);
      }
      const parsed = requestSchema.safeParse(
        JSON.parse(Buffer.concat(chunks).toString("utf8")),
      );
      if (!parsed.success) return send(400, { status: "invalid-request" });
      const result = await service.propose(parsed.data);
      return send(result.status === "unconnected" ? 503 : 200, result);
    } catch {
      return send(503, { status: "held" });
    }
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  server.timeout = 5000;
  return {
    server,
    listen: () =>
      new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, "127.0.0.1", resolve);
      }),
  };
}
