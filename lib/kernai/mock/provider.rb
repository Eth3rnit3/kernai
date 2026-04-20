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
        @failures = {}
      end

      # Queue a response (consumed in order, last one repeats).
      def respond_with(*texts)
        @responses.concat(texts)
        self
      end

      # Same behavior as `respond_with` but indexed by step number for
      # scenarios where associating a response with its step is clearer
      # than positional ordering. Keys must be a contiguous run of
      # non-negative integers starting at 0; missing steps would break
      # the "last response repeats" contract.
      def respond_with_script(script)
        sorted_keys = script.keys.sort
        unless sorted_keys == (0..sorted_keys.max.to_i).to_a
          raise ArgumentError,
                'respond_with_script keys must be contiguous non-negative integers starting at 0, ' \
                "got #{sorted_keys.inspect}"
        end

        @responses = sorted_keys.map { |k| script[k] }
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

      # Schedule an exception at a specific call index (0-based). Lets
      # scenarios exercise provider-error branches deterministically,
      # without reaching for stub libraries. The raised class defaults to
      # Kernai::ProviderError — the same error the base provider contract
      # raises for wiring problems.
      def fail_on_step(step, error_class: Kernai::ProviderError, message: 'mock provider failure')
        @failures[step] = { class: error_class, message: message }
        self
      end

      def call(messages:, model:, generation: nil, &block)
        @calls << { messages: messages, model: model, generation: generation }
        maybe_raise_scheduled_failure

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        content = resolve_response(messages, model)
        @call_count += 1

        content.to_s.each_char { |c| block.call(c) } if block

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

      # --- Introspection helpers for scenario assertions ---

      # Messages the provider received at call index `i` (0-based).
      def messages_at(index)
        @calls.dig(index, :messages)
      end

      # GenerationOptions the provider received at call index `i`.
      def generation_at(index)
        @calls.dig(index, :generation)
      end

      def reset!
        @responses = []
        @call_count = 0
        @calls = []
        @on_call = nil
        @token_provider = nil
        @failures = {}
      end

      private

      def maybe_raise_scheduled_failure
        entry = @failures[@call_count]
        return unless entry

        @call_count += 1
        raise entry[:class], entry[:message]
      end

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
