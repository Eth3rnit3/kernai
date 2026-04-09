# frozen_string_literal: true

require 'json'

module Kernai
  # Structured workflow plan emitted by the LLM inside a <block type="plan">.
  # A plan is a declarative description of tasks to run; the Kernel executes it
  # via the TaskScheduler and sub-agents.
  class Plan
    VALID_STRATEGIES = %w[parallel sequential mixed].freeze
    # Default honors each task's own `parallel` flag. The LLM can override
    # with "parallel" (run everything concurrently) or "sequential" (force
    # serial execution) as a global hint to the scheduler.
    DEFAULT_STRATEGY = 'mixed'

    attr_reader :goal, :strategy, :tasks

    class << self
      # Parse a raw plan representation (JSON string or Hash) into a Plan.
      # Returns nil for anything that fails validation (fail-safe).
      def parse(raw)
        data = coerce(raw)
        return nil unless data.is_a?(Hash)

        tasks_data = data['tasks']
        return nil unless tasks_data.is_a?(Array) && tasks_data.any?

        tasks = tasks_data.filter_map { |t| Task.from_hash(t) }
        return nil if tasks.empty?

        prune_invalid_dependencies(tasks)
        return nil if cyclic?(tasks)

        new(
          goal: data['goal'].to_s,
          strategy: VALID_STRATEGIES.include?(data['strategy']) ? data['strategy'] : DEFAULT_STRATEGY,
          tasks: tasks
        )
      end

      private

      def coerce(raw)
        return raw if raw.is_a?(Hash)
        return nil unless raw.is_a?(String)

        text = raw.strip
        return nil if text.empty?

        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end

      def prune_invalid_dependencies(tasks)
        ids = tasks.map(&:id)
        tasks.each do |t|
          t.depends_on = t.depends_on.select { |d| ids.include?(d) && d != t.id }
        end
      end

      def cyclic?(tasks)
        graph = tasks.each_with_object({}) { |t, h| h[t.id] = t.depends_on }
        state = {}
        tasks.any? { |t| cycle_from?(t.id, graph, state) }
      end

      def cycle_from?(node, graph, state)
        return false if state[node] == :done
        return true if state[node] == :visiting

        state[node] = :visiting
        (graph[node] || []).each do |dep|
          return true if cycle_from?(dep, graph, state)
        end
        state[node] = :done
        false
      end
    end

    def initialize(goal:, strategy:, tasks:)
      @goal = goal
      @strategy = strategy
      @tasks = tasks
    end

    def to_h
      {
        goal: @goal,
        strategy: @strategy,
        tasks: @tasks.map(&:to_h)
      }
    end
  end

  # A single executable unit within a plan. Each task is delegated to a
  # sub-agent by the TaskScheduler.
  class Task
    STATUSES = %i[pending running done].freeze

    attr_reader :id, :input
    attr_accessor :parallel, :depends_on, :status, :result

    class << self
      def from_hash(hash)
        return nil unless hash.is_a?(Hash)

        id = hash['id']
        input = hash['input']

        return nil unless id.is_a?(String) && !id.strip.empty?
        return nil unless input.is_a?(String) && !input.strip.empty?

        new(
          id: id,
          input: input,
          parallel: hash['parallel'] == true,
          depends_on: Array(hash['depends_on']).select { |d| d.is_a?(String) && !d.empty? },
          status: normalize_status(hash['status'])
        )
      end

      def normalize_status(value)
        return :pending if value.nil?

        sym = value.to_s.to_sym
        STATUSES.include?(sym) ? sym : :pending
      end
    end

    def initialize(id:, input:, parallel: false, depends_on: [], status: :pending)
      @id = id
      @input = input
      @parallel = parallel == true
      @depends_on = depends_on || []
      @status = status
      @result = nil
    end

    def pending?
      @status == :pending
    end

    def running?
      @status == :running
    end

    def done?
      @status == :done
    end

    def parallel?
      @parallel
    end

    def to_h
      h = {
        id: @id,
        input: @input,
        parallel: @parallel,
        depends_on: @depends_on,
        status: @status.to_s
      }
      h[:result] = @result unless @result.nil?
      h
    end
  end
end
