# frozen_string_literal: true

require 'json'
require 'time'

module Kernai
  # Append-only log of every kernel event. Entries are always stamped with
  # their execution scope (`depth` + `task_id`) so consumers can rebuild the
  # parent/sub-agent tree from the flat stream.
  class Recorder
    attr_reader :entries

    def initialize
      @entries = []
      @mutex = Mutex.new
    end

    def record(step:, event:, data:, scope: nil)
      scope ||= {}
      entry = {
        step: step,
        depth: scope[:depth] || 0,
        task_id: scope[:task_id],
        event: event.to_sym,
        data: data,
        timestamp: Time.now.iso8601(3)
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
