# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Kernai
  module Examples
    class AnthropicProvider < Kernai::Provider
      API_URL = 'https://api.anthropic.com/v1/messages'
      API_VERSION = '2023-06-01'

      def initialize(api_key: ENV['ANTHROPIC_API_KEY'])
        @api_key = api_key
      end

      def call(messages:, model:, &block)
        uri = URI(API_URL)
        system_msg, chat_messages = extract_system(messages)
        payload = build_payload(chat_messages, model, system: system_msg, stream: block_given?)

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

      private

      def extract_system(messages)
        system_msg = nil
        chat = messages.reject do |m|
          if m[:role].to_s == 'system'
            system_msg = m[:content]
            true
          end
        end
        [system_msg, chat]
      end

      def build_payload(messages, model, system: nil, stream: false)
        payload = {
          model: model,
          max_tokens: 4096,
          messages: messages.map { |m| { 'role' => m[:role].to_s, 'content' => m[:content] } }
        }
        payload[:system] = system if system
        payload[:stream] = true if stream
        payload
      end

      def http_post(uri, payload)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 120

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request['x-api-key'] = @api_key
        request['anthropic-version'] = API_VERSION
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
