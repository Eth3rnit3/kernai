# frozen_string_literal: true

require 'json'
require 'time'

module Kernai
  # Append-only log of every kernel event. Entries are always stamped with
  # their execution scope (`depth` + `task_id`) so consumers can rebuild the
  # parent/sub-agent tree from the flat stream.
  #
  # Persistence is handled by a pluggable Sink. The default MemorySink
  # keeps entries in RAM (matching the historical behavior), but host
  # applications can plug their own sink (DB, file, SSE fanout, ...)
  # without subclassing the Recorder. Use CompositeSink for fan-out.
  class Recorder
    # Sink contract: anything that implements `#record(entry)`. Sinks may
    # optionally expose `#entries` (for the in-memory query API) and
    # `#clear!`. The Recorder duck-types on those two when present.
    module Sink
      # Abstract base declaring the full sink surface. Custom sinks can
      # subclass this or simply implement `#record` on a plain object —
      # both are accepted.
      class Base
        def record(_entry)
          raise NotImplementedError, "#{self.class}#record must be implemented"
        end

        # A sink that does not materialise entries (e.g. a DB writer)
        # returns an empty array so the Recorder's query helpers stay
        # safe to call but yield nothing.
        def entries
          []
        end

        def clear!
          # Default no-op
        end
      end

      # Bundled sink that keeps every entry in a thread-safe Array.
      class MemorySink < Base
        attr_reader :entries

        def initialize
          super
          @entries = []
          @mutex = Mutex.new
        end

        def record(entry)
          @mutex.synchronize { @entries << entry }
        end

        def clear!
          @mutex.synchronize { @entries.clear }
        end
      end

      # Fan-out sink: forwards every entry to each child in declaration
      # order. Entry queries are delegated to the first child, which is
      # why MemorySink should usually be declared first when mixing it
      # with non-queryable persistence sinks.
      class CompositeSink < Base
        attr_reader :sinks

        def initialize(*sinks)
          super()
          raise ArgumentError, 'CompositeSink needs at least one child sink' if sinks.empty?

          @sinks = sinks
        end

        def record(entry)
          @sinks.each { |sink| sink.record(entry) }
        end

        def entries
          @sinks.first.entries
        end

        def clear!
          @sinks.each(&:clear!)
        end
      end
    end

    attr_reader :sink

    def initialize(sink: Sink::MemorySink.new)
      @sink = sink
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
      @sink.record(entry)
      entry
    end

    def entries
      @sink.entries
    end

    def to_a
      entries.dup
    end

    def to_json(*_args)
      JSON.pretty_generate(entries)
    end

    def clear!
      @sink.clear!
    end

    def steps
      entries.map { |e| e[:step] }.uniq.sort
    end

    def for_step(step)
      entries.select { |e| e[:step] == step }
    end

    def for_event(event)
      entries.select { |e| e[:event] == event.to_sym }
    end

    # --- Token accounting ---
    #
    # These helpers aggregate `:llm_response` entries. They require the
    # provider to fill `LlmResponse#prompt_tokens` / `#completion_tokens`
    # (`total_tokens` derives automatically when both prompt and
    # completion are populated — see `LlmResponse#initialize`).
    #
    # When no provider fills a given field, the aggregate value for that
    # field is `nil` — the caller can detect "unknown" vs "zero" without
    # ambiguity.

    # @return [Hash{Symbol => Integer, nil}] aggregate usage across every
    #   `:llm_response` entry in the recorder.
    def token_usage
      build_usage(for_event(:llm_response).map { |e| e[:data] })
    end

    # @return [Hash{Integer => Hash}] usage grouped by step.
    def token_usage_per_step
      for_event(:llm_response).group_by { |e| e[:step] }.transform_values do |entries|
        build_usage(entries.map { |e| e[:data] })
      end
    end

    # @return [Hash{String,Symbol => Hash}] usage grouped by `task_id`.
    #   Root-agent turns are keyed under `:root`.
    def token_usage_per_task
      for_event(:llm_response).group_by { |e| e[:task_id] || :root }.transform_values do |entries|
        build_usage(entries.map { |e| e[:data] })
      end
    end

    private

    def build_usage(data_entries)
      {
        prompt_tokens: sum_field(data_entries, :prompt_tokens),
        completion_tokens: sum_field(data_entries, :completion_tokens),
        total_tokens: sum_field(data_entries, :total_tokens)
      }
    end

    def sum_field(data_entries, key)
      values = data_entries.map { |d| d[key] }.compact
      values.empty? ? nil : values.sum
    end
  end
end
