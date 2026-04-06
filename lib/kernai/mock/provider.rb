# frozen_string_literal: true

module Kernai
  module Mock
    class Provider < Kernai::Provider
      attr_reader :calls

      def initialize
        @responses = []
        @call_count = 0
        @calls = []
        @on_call = nil
      end

      # Queue a response (consumed in order, last one repeats)
      def respond_with(*texts)
        @responses.concat(texts)
        self
      end

      # Set a dynamic response handler
      def on_call(&block)
        @on_call = block
        self
      end

      def call(messages:, model:, &block)
        @calls << { messages: messages, model: model }

        response = resolve_response(messages, model)
        @call_count += 1

        if block
          response.each_char { |c| block.call(c) }
        end

        response
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
      end

      private

      def resolve_response(messages, model)
        if @on_call
          @on_call.call(messages, model)
        elsif @responses.any?
          index = [@call_count, @responses.size - 1].min
          @responses[index]
        else
          ""
        end
      end
    end
  end
end
