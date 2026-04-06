# frozen_string_literal: true

module Kernai
  class Provider
    # Call the LLM with messages
    # @param messages [Array<Hash>] conversation messages [{role:, content:}]
    # @param model [String] model identifier
    # @param block [Proc] optional streaming callback, receives chunks
    # @return [String] complete response text
    def call(messages:, model:, &block)
      raise NotImplementedError, "#{self.class}#call must be implemented"
    end
  end
end
