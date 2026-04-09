# frozen_string_literal: true

module Kernai
  # Execution context passed through Kernel.run. It holds the active plan,
  # its tasks, accumulated task results and recursion depth. Sub-agents
  # receive a fresh child context so their state never pollutes the parent.
  class Context
    attr_reader :depth
    attr_accessor :plan, :tasks, :task_results

    def initialize(plan: nil, tasks: nil, task_results: nil, depth: 0)
      @plan = plan
      @tasks = tasks || []
      @task_results = task_results || {}
      @depth = depth
      @mutex = Mutex.new
    end

    def root?
      @depth.zero?
    end

    # Thread-safe write — used by the TaskScheduler running parallel tasks.
    def record_result(task_id, result)
      @mutex.synchronize { @task_results[task_id.to_s] = result }
    end

    # Replace current task list with a fresh copy built from the plan so
    # the context can be mutated independently of the source plan.
    def hydrate_from_plan(plan)
      @plan = plan
      @tasks = plan.tasks.map do |t|
        Task.new(
          id: t.id,
          input: t.input,
          parallel: t.parallel,
          depends_on: t.depends_on.dup,
          status: :pending
        )
      end
      @task_results = {}
    end

    # Build an isolated child context for a sub-agent. Depth is incremented
    # so nested plans can be detected and ignored.
    def spawn_child
      self.class.new(depth: @depth + 1)
    end

    def to_h
      {
        plan: @plan&.to_h,
        tasks: @tasks.map(&:to_h),
        task_results: @task_results,
        depth: @depth
      }
    end
  end
end
