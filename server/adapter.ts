/** Server-only provider protocol. Production start does not bind a sender or secret. */
export interface GenerationAdapter {
  readonly kind: "test-only" | "prepared";
  readonly protocol: "provider-v1";
  generate(
    payload: {
      question: string;
      excerpt: string;
      sources: { id: string; body: string }[];
    },
    options: {
      model: string;
      inputTokens: number;
      outputTokens: number;
      signal: AbortSignal;
      retries: 0;
      store: false;
      tools: readonly [];
      tokenCountMargin: number;
      tokenCountTermsConfirmed: true;
    },
  ): Promise<{
    json: string;
    usage: { inputTokens: number; outputTokens: number };
    outcome:
      "complete" | "refused" | "incomplete" | "invalid-output" | "input-limit";
  }>;
}
