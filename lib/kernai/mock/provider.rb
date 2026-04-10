# frozen_string_literal: true

module Kernai
  module Mock
    class Provider < Kernai::Provider
      attr_reader :calls

      def initialize
        super
        @responses = []
        @call_count = 0
        @calls = []
        @on_call = nil
        @token_provider = nil
      end

      # Queue a response (consumed in order, last one repeats).
      def respond_with(*texts)
        @responses.concat(texts)
        self
      end

      # Set a dynamic response handler.
      def on_call(&block)
        @on_call = block
        self
      end

      # Optional: deterministic token counter used by tests that assert on
      # usage data. Receives (messages, content) and must return a hash
      # like { prompt_tokens:, completion_tokens: }.
      def with_token_counter(&block)
        @token_provider = block
        self
      end

      def call(messages:, model:, &block)
        @calls << { messages: messages, model: model }

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        content = resolve_response(messages, model)
        @call_count += 1

        content.each_char { |c| block.call(c) } if block

        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        tokens = @token_provider&.call(messages, content) || {}

        LlmResponse.new(
          content: content,
          latency_ms: latency_ms,
          prompt_tokens: tokens[:prompt_tokens],
          completion_tokens: tokens[:completion_tokens]
        )
      end

      def call_count
        @calls.size
      end

      def last_call
        @calls.last
      end

      def reset!
        @responses = []
        @call_count = 0
        @calls = []
        @on_call = nil
        @token_provider = nil
      end

      private

      def resolve_response(messages, model)
        if @on_call
          @on_call.call(messages, model)
        elsif @responses.any?
          index = [@call_count, @responses.size - 1].min
          @responses[index]
        else
          ''
        end
      end
    end
  end
end
