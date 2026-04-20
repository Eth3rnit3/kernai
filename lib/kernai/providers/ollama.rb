# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Kernai
  module Providers
    # Kernai::Provider adapter for the Ollama chat API.
    #
    # Supports streaming, multimodal image input (when the model declares
    # `:vision`; only inline-bytes images are accepted — Ollama does not
    # fetch URLs). GenerationOptions are routed under Ollama's `options`
    # map, with `max_tokens` surfaced as `num_predict`.
    #
    # Zero runtime dependencies beyond the Ruby stdlib. Points at
    # `localhost:11434` by default; override with `base_url:` for remote
    # deployments.
    class Ollama < Kernai::Provider
      DEFAULT_BASE_URL = 'http://localhost:11434'

      def initialize(api_key: ENV.fetch('OLLAMA_API_KEY', nil),
                     base_url: ENV.fetch('OLLAMA_BASE_URL', DEFAULT_BASE_URL))
        super()
        @api_key = api_key
        @base_url = base_url.chomp('/')
      end

      def call(messages:, model:, generation: nil, &block)
        uri = URI("#{@base_url}/api/chat")
        payload = build_payload(messages, model, stream: block_given?, generation: generation)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        content, usage = if block
                           stream_request(uri, payload, &block)
                         else
                           non_stream_request(uri, payload)
                         end

        Kernai::LlmResponse.new(
          content: content,
          latency_ms: elapsed_ms(started),
          prompt_tokens: usage['prompt_eval_count'],
          completion_tokens: usage['eval_count']
        )
      end

      # Strings become text parts; inline base64 images become image
      # parts when the model declares `:vision`. URL-backed images and
      # non-image media fall back to the base class placeholder, which
      # re-enters this method and is wrapped as a text part.
      def encode_part(part, model:)
        return { type: :text, text: part } if part.is_a?(String)
        return nil unless part.is_a?(Kernai::Media) && part.kind == :image && model.supports?(:vision)
        return nil if part.url?

        { type: :image, data: part.to_base64 }
      end

      private

      # Ollama's chat API carries text in `content` and tucks inline image
      # bytes into a sibling `images` array (base64 strings). Parts are
      # emitted as tagged hashes so build_message can route them to the
      # right field without guessing whether a bare String is user text
      # or a base64 blob.
      def build_payload(messages, model, stream: false, generation: nil)
        payload = {
          model: model.id,
          messages: messages.map { |m| build_message(m, model) },
          stream: stream
        }
        apply_generation!(payload, generation)
        payload
      end

      # Ollama nests generation knobs under `options`. `max_tokens` is
      # surfaced by Ollama as `num_predict`. Unknown fields are ignored.
      def apply_generation!(payload, generation)
        return if generation.nil? || generation.empty?

        options = {}
        options[:temperature] = generation.temperature if generation.temperature
        options[:top_p]       = generation.top_p       if generation.top_p
        options[:num_predict] = generation.max_tokens  if generation.max_tokens
        payload[:options] = options unless options.empty?
      end

      def build_message(msg, model)
        encoded = encode(msg[:content], model: model)
        text = encoded.select { |p| p[:type] == :text }.map { |p| p[:text] }.join
        images = encoded.select { |p| p[:type] == :image }.map { |p| p[:data] }

        payload = { 'role' => msg[:role].to_s, 'content' => text }
        payload['images'] = images unless images.empty?
        payload
      end

      def non_stream_request(uri, payload)
        response = http_post(uri, payload)

        unless response.is_a?(Net::HTTPSuccess)
          raise Kernai::ProviderError, "Ollama API error #{response.code}: #{response.body}"
        end

        parse_response(response.body)
      end

      def http_post(uri, payload)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.read_timeout = 300

        request = build_request(uri, payload)
        http.request(request)
      end

      def build_request(uri, payload)
        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{@api_key}" if @api_key
        request.body = JSON.generate(payload)
        request
      end

      def parse_response(body)
        data = JSON.parse(body)
        content = data.dig('message', 'content') || ''
        [content, data]
      end

      def stream_request(uri, payload, &block)
        full_text = +''
        final_usage = {}

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.read_timeout = 300

        request = build_request(uri, payload)

        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise Kernai::ProviderError, "Ollama API error #{response.code}: #{response.body}"
          end

          buffer = +''

          response.read_body do |chunk|
            buffer << chunk

            while (idx = buffer.index("\n"))
              line = buffer.slice!(0, idx + 1).strip
              next if line.empty?

              final_usage = consume_stream_line(line, full_text, &block)
            end
          end

          final_usage = consume_stream_line(buffer.strip, full_text, &block) unless buffer.strip.empty?
        end

        [full_text, final_usage]
      end

      # Parses one JSON line from the Ollama stream, appends any delta to
      # `full_text` and yields it to the caller. Returns the raw hash so the
      # final `done: true` frame (which carries prompt_eval_count /
      # eval_count) can surface as usage metadata.
      def consume_stream_line(line, full_text, &block)
        parsed = JSON.parse(line)
        content = parsed.dig('message', 'content')
        if content && !content.empty?
          full_text << content
          block.call(content)
        end
        parsed
      end

      def elapsed_ms(started)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      end
    end
  end
end
