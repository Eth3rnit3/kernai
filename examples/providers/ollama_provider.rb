# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Kernai
  module Examples
    class OllamaProvider < Kernai::Provider
      DEFAULT_BASE_URL = 'http://localhost:11434'

      def initialize(api_key: ENV['OLLAMA_API_KEY'], base_url: ENV.fetch('OLLAMA_BASE_URL', DEFAULT_BASE_URL))
        @api_key = api_key
        @base_url = base_url.chomp('/')
      end

      def call(messages:, model:, &block)
        uri = URI("#{@base_url}/api/chat")
        payload = build_payload(messages, model, stream: block_given?)

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

      private

      def build_payload(messages, model, stream: false)
        {
          model: model,
          messages: messages.map { |m| { 'role' => m[:role].to_s, 'content' => m[:content] } },
          stream: stream
        }
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
