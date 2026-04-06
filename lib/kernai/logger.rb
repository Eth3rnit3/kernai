# frozen_string_literal: true

module Kernai
  class Logger
    attr_accessor :output

    def initialize(output = $stdout)
      @output = output
    end

    def debug(message = nil, **data)
      log(:DEBUG, message, **data)
    end

    def info(message = nil, **data)
      log(:INFO, message, **data)
    end

    def warn(message = nil, **data)
      log(:WARN, message, **data)
    end

    def error(message = nil, **data)
      log(:ERROR, message, **data)
    end

    private

    def log(level, message, **data)
      return unless Kernai.config.debug || level != :DEBUG

      entry = { level: level, timestamp: Time.now.iso8601 }
      entry[:message] = message if message
      entry.merge!(data) unless data.empty?

      output.puts(format_entry(entry))
    end

    def format_entry(entry)
      parts = entry.reject { |k, _| %i[level timestamp].include?(k) }.map { |k, v| "#{k}=#{v}" }.join(' ')
      "[Kernai] #{entry[:level]} #{parts}"
    end
  end
end
