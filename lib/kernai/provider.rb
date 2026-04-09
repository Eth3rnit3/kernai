# frozen_string_literal: true

module Kernai
  class Provider
    # Call the LLM with messages.
    #
    # @param messages [Array<Hash>] conversation messages [{role:, content:}]
    # @param model [String] model identifier
    # @param block [Proc] optional streaming callback, receives text chunks
    # @return [Kernai::LlmResponse] content + latency + token usage
    def call(messages:, model:, &block)
      raise NotImplementedError, "#{self.class}#call must be implemented"
    end
  end
end
