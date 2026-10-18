import {
  minimalPayload,
  normalizeOutput,
  outputSchema,
  systemPrompt,
} from "./provider-format.mjs";
import {
  postJson,
  checkOptions,
  secretHeaders,
  tokenCount,
} from "./provider-http.mjs";

export function anthropicTransport({ send, secret, mockOnly = false }) {
  return {
    kind: mockOnly ? "test-only" : "prepared",
    protocol: "provider-v1",
    async generate(payload, options) {
      checkOptions(options, "claude-haiku-5-5");
      const headers = secretHeaders(secret, "anthropic");
      const common = {
        model: options.model,
        messages: [
          { role: "user", content: JSON.stringify(minimalPayload(payload)) },
        ],
        system: systemPrompt,
        thinking: { type: "disabled" },
        output_config: {
          effort: "low",
          format: { type: "json_schema", schema: outputSchema },
        },
      };
      const counted = await postJson(
        send,
        "https://api.anthropic.com/v1/messages/count_tokens",
        headers,
        common,
        options.signal,
      );
      if (
        tokenCount(counted.input_tokens) + options.tokenCountMargin >
        options.inputTokens
      )
        return {
          json: "",
          usage: { inputTokens: 0, outputTokens: 0 },
          outcome: "input-limit",
        };
      const response = await postJson(
        send,
        "https://api.anthropic.com/v1/messages",
        headers,
        {
          ...common,
          stream: false,
          max_tokens: options.outputTokens,
          service_tier: "standard_only",
          inference_geo: "global",
        },
        options.signal,
      );
      // Cache input counts are disjoint from input_tokens; all input is charged at the registry upper rate.
      const usage = {
        inputTokens:
          tokenCount(response.usage?.input_tokens) +
          tokenCount(response.usage?.cache_creation_input_tokens ?? 0) +
          tokenCount(response.usage?.cache_read_input_tokens ?? 0),
        outputTokens: tokenCount(response.usage?.output_tokens),
      };
      if (
        response.model !== options.model ||
        response.usage?.service_tier !== "standard" ||
        (response.usage?.inference_geo &&
          response.usage.inference_geo !== "global") ||
        Object.values(response.usage?.server_tool_use ?? {}).some(
          (n) => n !== 0,
        ) ||
        tokenCount(
          response.usage?.output_tokens_details?.thinking_tokens ?? 0,
        ) > usage.outputTokens
      )
        throw Error("usage-unconfirmed");
      let json = "";
      let outcome = "invalid-output";
      if (
        response.stop_reason === "end_turn" &&
        response.stop_details?.type !== "refusal" &&
        response.type === "message" &&
        Array.isArray(response.content) &&
        response.content.length === 1 &&
        response.content[0].type === "text"
      ) {
        try {
          json = normalizeOutput(response.content[0].text);
          outcome = "complete";
        } catch {
          /* Paid output fails local validation. */
        }
      } else if (
        response.stop_reason === "refusal" ||
        response.stop_details?.type === "refusal"
      )
        outcome = "refused";
      else if (response.stop_reason === "max_tokens") outcome = "incomplete";
      return { json, usage, outcome };
    },
  };
}
