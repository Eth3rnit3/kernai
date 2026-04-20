# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Kernai
  module Providers
    # Kernai::Provider adapter for the Anthropic Messages API.
    #
    # Supports streaming, multimodal image input (when the model
    # declares `:vision`), and extended thinking via
    # `GenerationOptions#thinking[:budget]`. Vendor-specific fields
    # inside `GenerationOptions#extra` are ignored silently.
    #
    # Zero runtime dependencies beyond the Ruby stdlib.
    #
    # @example
    #   provider = Kernai::Providers::Anthropic.new(api_key: ENV["ANTHROPIC_API_KEY"])
    #   agent = Kernai::Agent.new(
    #     instructions: "You are a helpful assistant.",
    #     provider: provider,
    #     model: Kernai::Models::CLAUDE_SONNET_4,
    #     generation: { thinking: { budget: 10_000 }, max_tokens: 12_000 }
    #   )
    class Anthropic < Kernai::Provider
      DEFAULT_API_URL = 'https://api.anthropic.com/v1/messages'
      DEFAULT_API_VERSION = '2023-06-01'
      DEFAULT_MAX_TOKENS = 4096

      def initialize(api_key: ENV.fetch('ANTHROPIC_API_KEY', nil),
                     api_url: DEFAULT_API_URL,
                     api_version: DEFAULT_API_VERSION)
        super()
        @api_key = api_key
        @api_url = api_url
        @api_version = api_version
      end

      def call(messages:, model:, generation: nil, &block)
        uri = URI(@api_url)
        system_msg, chat_messages = extract_system(messages, model)
        payload = build_payload(chat_messages, model,
                                system: system_msg, stream: block_given?, generation: generation)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = http_post(uri, payload)

        unless response.is_a?(Net::HTTPSuccess)
          raise Kernai::ProviderError, "Anthropic API error #{response.code}: #{response.body}"
        end

        content, usage = if block
                           parse_stream(response.body, &block)
                         else
                           parse_response(response.body)
                         end

        Kernai::LlmResponse.new(
          content: content,
          latency_ms: elapsed_ms(started),
          prompt_tokens: usage[:input_tokens],
          completion_tokens: usage[:output_tokens]
        )
      end

      # Strings are always wrapped as `{type: text, text: ...}` so the
      # content array is homogeneous (Anthropic rejects mixed
      # String/Hash arrays). Images — only when the model declares
      # `:vision`. Any other media kind falls back to the base class
      # placeholder, which is itself a String and will re-enter this
      # method to be wrapped as a text block.
      def encode_part(part, model:)
        return { 'type' => 'text', 'text' => part } if part.is_a?(String)
        return nil unless part.is_a?(Kernai::Media) && part.kind == :image && model.supports?(:vision)

        case part.source
        when :url
          { 'type' => 'image', 'source' => { 'type' => 'url', 'url' => part.data } }
        when :path, :bytes
          {
            'type' => 'image',
            'source' => {
              'type' => 'base64',
              'media_type' => part.mime_type,
              'data' => part.to_base64
            }
          }
        end
      end

      private

      # Anthropic expects `content` as a list of typed blocks — never a
      # raw mixed array. The system message is an exception: it lives
      # outside `messages` as a plain string, so we flatten it by
      # extracting the `.text` field from the encoded text blocks.
      def extract_system(messages, model)
        system_msg = nil
        chat = messages.reject do |m|
          if m[:role].to_s == 'system'
            system_msg = encode(m[:content], model: model).map { |p| p['text'] }.compact.join
            true
          end
        end
        [system_msg, chat]
      end

      def build_payload(messages, model, system: nil, stream: false, generation: nil)
        payload = {
          model: model.id,
          max_tokens: DEFAULT_MAX_TOKENS,
          messages: messages.map do |m|
            { 'role' => m[:role].to_s, 'content' => encode(m[:content], model: model) }
          end
        }
        payload[:system] = system if system
        payload[:stream] = true if stream
        apply_generation!(payload, generation)
        payload
      end

      # Route Kernai::GenerationOptions into Anthropic-native params.
      # Silently ignores fields the vendor doesn't understand (e.g. :effort
      # inside :thinking) so the options object stays portable across
      # providers.
      def apply_generation!(payload, generation)
        return if generation.nil? || generation.empty?

        payload[:temperature] = generation.temperature if generation.temperature
        payload[:max_tokens]  = generation.max_tokens  if generation.max_tokens
        payload[:top_p]       = generation.top_p       if generation.top_p
        thinking = generation.thinking
        return unless thinking && thinking[:budget]

        payload[:thinking] = { type: 'enabled', budget_tokens: thinking[:budget] }
      end

      def http_post(uri, payload)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 120

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request['x-api-key'] = @api_key
        request['anthropic-version'] = @api_version
        request.body = JSON.generate(payload)

        http.request(request)
      end

      def parse_response(body)
        data = JSON.parse(body)
        content_blocks = data['content'] || []
        text = content_blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join
        raw_usage = data['usage'] || {}
        [text, { input_tokens: raw_usage['input_tokens'], output_tokens: raw_usage['output_tokens'] }]
      end

      def parse_stream(body, &block)
        full_text = +''
        usage = { input_tokens: nil, output_tokens: nil }

        body.each_line do |line|
          line = line.strip
          next if line.empty?
          next unless line.start_with?('data: ')

          parsed = JSON.parse(line.sub('data: ', ''))
          type = parsed['type']

          case type
          when 'message_start'
            start_usage = parsed.dig('message', 'usage') || {}
            usage[:input_tokens] = start_usage['input_tokens']
            usage[:output_tokens] = start_usage['output_tokens']
          when 'message_delta'
            delta_usage = parsed['usage'] || {}
            usage[:output_tokens] = delta_usage['output_tokens'] if delta_usage['output_tokens']
          when 'content_block_delta'
            text = parsed.dig('delta', 'text')
            next unless text && !text.empty?

            full_text << text
            block.call(text)
          end
        end

        [full_text, usage]
      end

      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end
    end
  end
end
