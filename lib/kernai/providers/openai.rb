# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Kernai
  module Providers
    # Kernai::Provider adapter for the OpenAI Chat Completions API.
    #
    # Supports streaming, multimodal image input (when the model declares
    # `:vision`), and reasoning effort via `GenerationOptions#thinking[:effort]`
    # which maps to OpenAI's `reasoning_effort` parameter (honored by o1/o3/
    # gpt-5 reasoning models; silently ignored by others).
    #
    # Zero runtime dependencies beyond the Ruby stdlib. Works against any
    # OpenAI-compatible endpoint by passing a custom `api_url:`.
    class Openai < Kernai::Provider
      DEFAULT_API_URL = 'https://api.openai.com/v1/chat/completions'

      def initialize(api_key: ENV.fetch('OPENAI_API_KEY', nil), api_url: DEFAULT_API_URL)
        super()
        @api_key = api_key
        @api_url = api_url
      end

      def call(messages:, model:, generation: nil, &block)
        uri = URI(@api_url)
        payload = build_payload(messages, model, stream: block_given?, generation: generation)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = http_post(uri, payload)

        unless response.is_a?(Net::HTTPSuccess)
          raise Kernai::ProviderError, "OpenAI API error #{response.code}: #{response.body}"
        end

        content, usage = if block
                           parse_stream(response.body, &block)
                         else
                           parse_response(response.body)
                         end

        Kernai::LlmResponse.new(
          content: content,
          latency_ms: elapsed_ms(started),
          prompt_tokens: usage['prompt_tokens'],
          completion_tokens: usage['completion_tokens'],
          total_tokens: usage['total_tokens']
        )
      end

      # OpenAI chat completions accept vision parts as `image_url` objects.
      # We honour both URL-backed media and inline bytes (encoded as a data
      # URI). Anything else falls back to the base class placeholder.
      def encode_part(part, model:)
        return { 'type' => 'text', 'text' => part } if part.is_a?(String)
        return nil unless part.is_a?(Kernai::Media) && part.kind == :image && model.supports?(:vision)

        url = case part.source
              when :url then part.data
              when :path, :bytes then "data:#{part.mime_type};base64,#{part.to_base64}"
              end
        { 'type' => 'image_url', 'image_url' => { 'url' => url } }
      end

      private

      def build_payload(messages, model, stream: false, generation: nil)
        payload = {
          model: model.id,
          messages: messages.map do |m|
            { 'role' => m[:role].to_s, 'content' => encode(m[:content], model: model) }
          end
        }
        if stream
          payload[:stream] = true
          payload[:stream_options] = { 'include_usage' => true }
        end
        apply_generation!(payload, generation)
        payload
      end

      # Route Kernai::GenerationOptions into OpenAI-native params. The
      # `:thinking[:effort]` field maps to the newer `reasoning_effort`
      # param accepted by the o-series / gpt-5 reasoning models; older
      # models silently ignore it.
      def apply_generation!(payload, generation)
        return if generation.nil? || generation.empty?

        payload[:temperature] = generation.temperature if generation.temperature
        payload[:max_tokens]  = generation.max_tokens  if generation.max_tokens
        payload[:top_p]       = generation.top_p       if generation.top_p
        thinking = generation.thinking
        return unless thinking

        payload[:reasoning_effort] = thinking[:effort].to_s if thinking[:effort]
      end

      def http_post(uri, payload)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.read_timeout = 120

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{@api_key}"
        request.body = JSON.generate(payload)

        http.request(request)
      end

      def parse_response(body)
        data = JSON.parse(body)
        content = data.dig('choices', 0, 'message', 'content') || ''
        usage = data['usage'] || {}
        [content, usage]
      end

      def parse_stream(body, &block)
        full_text = +''
        usage = {}

        body.each_line do |line|
          line = line.strip
          next if line.empty?
          next unless line.start_with?('data: ')

          payload = line.sub('data: ', '')
          next if payload == '[DONE]'

          parsed = JSON.parse(payload)
          delta = parsed.dig('choices', 0, 'delta', 'content')
          if delta && !delta.empty?
            full_text << delta
            block.call(delta)
          end

          usage = parsed['usage'] if parsed['usage']
        end

        [full_text, usage]
      end

      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end
    end
  end
end
