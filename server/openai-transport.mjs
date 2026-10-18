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

export function openaiTransport({ send, secret, mockOnly = false }) {
  // Not installed in start.mjs. A prepared transport is rejected by GenerationService.
  return {
    kind: mockOnly ? "test-only" : "prepared",
    protocol: "provider-v1",
    async generate(payload, options) {
      checkOptions(options, "gpt-6-luna");
      const headers = secretHeaders(secret, "openai");
      const common = {
        model: options.model,
        input: [
          { role: "user", content: JSON.stringify(minimalPayload(payload)) },
        ],
        instructions: systemPrompt,
        reasoning: { effort: "none" },
        tools: [],
        text: {
          format: {
            type: "json_schema",
            name: "caa_addition",
            strict: true,
            schema: outputSchema,
          },
        },
      };
      const counted = await postJson(
        send,
        "https://api.openai.com/v1/responses/input_tokens",
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
        "https://api.openai.com/v1/responses",
        headers,
        {
          ...common,
          store: false,
          stream: false,
          max_output_tokens: options.outputTokens,
          service_tier: "default",
        },
        options.signal,
      );
      const usage = {
        inputTokens: tokenCount(response.usage?.input_tokens),
        outputTokens: tokenCount(response.usage?.output_tokens),
      };
      if (
        tokenCount(response.usage?.total_tokens) !==
          usage.inputTokens + usage.outputTokens ||
        tokenCount(response.usage?.input_tokens_details?.cached_tokens ?? 0) >
          usage.inputTokens ||
        tokenCount(
          response.usage?.output_tokens_details?.reasoning_tokens ?? 0,
        ) > usage.outputTokens ||
        (Array.isArray(response.output) &&
          response.output.some(
            (item) => !["message", "reasoning"].includes(item.type),
          )) ||
        response.service_tier !== "default" ||
        response.model !== options.model
      )
        throw Error("usage-unconfirmed");
      // Total output_tokens already includes reasoning; do not add reasoning tokens twice.
      let json = "";
      let outcome = "invalid-output";
      const content = Array.isArray(response.output)
        ? response.output.flatMap((item) =>
            item.type === "message" ? (item.content ?? []) : [],
          )
        : [];
      if (
        response.status === "completed" &&
        !response.error &&
        content.length === 1 &&
        content[0].type === "output_text"
      ) {
        try {
          json = normalizeOutput(content[0].text);
          outcome = "complete";
        } catch {
          /* Paid output fails local validation. */
        }
      } else if (content.some((c) => c.type === "refusal")) outcome = "refused";
      else if (response.status === "incomplete") outcome = "incomplete";
      return { json, usage, outcome };
    },
  };
}
