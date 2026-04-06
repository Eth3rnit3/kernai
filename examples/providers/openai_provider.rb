# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Kernai
  module Examples
    class OpenaiProvider < Kernai::Provider
      API_URL = 'https://api.openai.com/v1/chat/completions'

      def initialize(api_key: ENV['OPENAI_API_KEY'])
        @api_key = api_key
      end

      def call(messages:, model:, &block)
        uri = URI(API_URL)
        payload = build_payload(messages, model, stream: block_given?)

        response = http_post(uri, payload)

        unless response.is_a?(Net::HTTPSuccess)
          raise Kernai::ProviderError, "OpenAI API error #{response.code}: #{response.body}"
        end

        if block
          parse_stream(response.body, &block)
        else
          parse_response(response.body)
        end
      end

      private

      def build_payload(messages, model, stream: false)
        payload = {
          model: model,
          messages: messages.map { |m| { 'role' => m[:role].to_s, 'content' => m[:content] } }
        }
        payload[:stream] = true if stream
        payload
      end

      def http_post(uri, payload)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 120

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{@api_key}"
        request.body = JSON.generate(payload)

        http.request(request)
      end

      def parse_response(body)
        data = JSON.parse(body)
        data.dig('choices', 0, 'message', 'content') || ''
      end

      def parse_stream(body, &block)
        full_text = +''

        body.each_line do |line|
          line = line.strip
          next if line.empty?
          next unless line.start_with?('data: ')

          data = line.sub('data: ', '')
          next if data == '[DONE]'

          parsed = JSON.parse(data)
          content = parsed.dig('choices', 0, 'delta', 'content')
          if content && !content.empty?
            full_text << content
            block.call(content)
          end
        end

        full_text
      end
    end
  end
end
