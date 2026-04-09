# frozen_string_literal: true

module Kernai
  # Structured response returned by every Provider#call. Carries the model's
  # text output alongside deterministic observability metadata (latency,
  # token usage). Providers that can't report a field leave it nil — the
  # Kernel and recorder handle that uniformly without any conditional
  # branching at the call sites.
  class LlmResponse
    attr_reader :content, :latency_ms, :prompt_tokens, :completion_tokens, :total_tokens

    def initialize(content:, latency_ms:, prompt_tokens: nil, completion_tokens: nil, total_tokens: nil)
      @content = content.to_s
      @latency_ms = latency_ms.to_i
      @prompt_tokens = prompt_tokens
      @completion_tokens = completion_tokens
      @total_tokens = total_tokens || derived_total(prompt_tokens, completion_tokens)
    end

    def to_h
      {
        content: @content,
        latency_ms: @latency_ms,
        prompt_tokens: @prompt_tokens,
        completion_tokens: @completion_tokens,
        total_tokens: @total_tokens
      }
    end

    private

    def derived_total(prompt, completion)
      return nil if prompt.nil? && completion.nil?

      prompt.to_i + completion.to_i
    end
  end
end
