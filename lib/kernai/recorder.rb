# frozen_string_literal: true

require 'json'

module Kernai
  class Recorder
    attr_reader :entries

    def initialize
      @entries = []
      @mutex = Mutex.new
    end

    def record(step:, event:, data:)
      entry = {
        step: step,
        event: event.to_sym,
        data: data,
        timestamp: Time.now.iso8601
      }
      @mutex.synchronize { @entries << entry }
    end

    def to_a
      @entries.dup
    end

    def to_json(*_args)
      JSON.pretty_generate(@entries)
    end

    def clear!
      @entries.clear
    end

    def steps
      @entries.map { |e| e[:step] }.uniq.sort
    end

    def for_step(step)
      @entries.select { |e| e[:step] == step }
    end

    def for_event(event)
      @entries.select { |e| e[:event] == event.to_sym }
    end
  end
end
