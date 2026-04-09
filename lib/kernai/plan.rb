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

    # Symbols returned by Plan.validate when a raw payload is rejected.
    REJECTION_REASONS = %i[
      blank
      invalid_json
      not_a_hash
      no_tasks
      empty_tasks
      all_tasks_invalid
      cyclic
    ].freeze

    # Small value object returned by Plan.validate. `plan` is set only on
    # success; `reason` is set only on failure.
    Result = Struct.new(:plan, :reason, keyword_init: true) do
      def ok?
        !plan.nil?
      end
    end

    attr_reader :goal, :strategy, :tasks

    class << self
      # Convenience wrapper — returns the Plan or nil. Use `validate` when
      # the caller also needs the rejection reason.
      def parse(raw)
        validate(raw).plan
      end

      # Full parsing pipeline with structured failure reasons. Always
      # returns a Result; the caller decides whether to surface `reason`.
      def validate(raw)
        data, reason = coerce(raw)
        return Result.new(reason: reason) if reason

        tasks_data = data['tasks']
        return Result.new(reason: :no_tasks)    unless tasks_data.is_a?(Array)
        return Result.new(reason: :empty_tasks) if tasks_data.empty?

        tasks = tasks_data.filter_map { |t| Task.from_hash(t) }
        return Result.new(reason: :all_tasks_invalid) if tasks.empty?

        prune_invalid_dependencies(tasks)
        return Result.new(reason: :cyclic) if cyclic?(tasks)

        plan = new(
          goal: data['goal'].to_s,
          strategy: VALID_STRATEGIES.include?(data['strategy']) ? data['strategy'] : DEFAULT_STRATEGY,
          tasks: tasks
        )
        Result.new(plan: plan)
      end

      private

      # Normalizes any accepted input shape into a Hash. Returns
      # [hash, nil] on success or [nil, reason] on failure so `validate`
      # can forward the reason unchanged.
      def coerce(raw)
        return [raw, nil] if raw.is_a?(Hash)
        return [nil, :not_a_hash] unless raw.is_a?(String)

        text = raw.strip
        return [nil, :blank] if text.empty?

        [JSON.parse(text), nil]
      rescue JSON::ParserError
        [nil, :invalid_json]
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
