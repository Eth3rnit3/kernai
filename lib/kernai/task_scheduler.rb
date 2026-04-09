# frozen_string_literal: true

module Kernai
  # Executes the tasks stored in a Context, respecting dependencies and
  # parallelism flags. The scheduler is intentionally dumb: it has no
  # knowledge of LLMs, agents or providers. A `runner` callable receives
  # (task, context) and is expected to return the task result.
  #
  # The scheduling strategy is read from `context.plan.strategy`:
  # - "sequential" forces every ready task to run serially
  # - "parallel"   forces every ready task to run concurrently
  # - "mixed"      (default) honors each task's own `parallel` flag
  class TaskScheduler
    # Raised when pending tasks remain but none are ready — i.e. the task
    # graph cannot progress.
    class DeadlockError < StandardError; end

    STRATEGIES = %w[sequential parallel mixed].freeze
    DEFAULT_STRATEGY = 'mixed'

    def initialize(context, runner)
      @context = context
      @runner = runner
      @strategy = resolve_strategy(context.plan&.strategy)
    end

    # Run all tasks until the graph is complete. Returns the final
    # task_results hash.
    def run
      loop do
        ready = ready_tasks

        if ready.empty?
          pending = @context.tasks.reject(&:done?)
          raise DeadlockError, "Tasks could not complete: #{pending.map(&:id).join(', ')}" if pending.any?

          break
        end

        parallel, sequential = ready.partition { |t| effective_parallel?(t) }

        run_parallel(parallel) if parallel.any?
        run_sequential(sequential) if sequential.any?
      end

      @context.task_results
    end

    private

    def resolve_strategy(raw)
      return DEFAULT_STRATEGY if raw.nil?

      STRATEGIES.include?(raw) ? raw : DEFAULT_STRATEGY
    end

    def effective_parallel?(task)
      case @strategy
      when 'parallel' then true
      when 'sequential' then false
      else task.parallel?
      end
    end

    def ready_tasks
      @context.tasks.select do |task|
        task.pending? && task.depends_on.all? { |dep| dep_done?(dep) }
      end
    end

    def dep_done?(id)
      task = @context.tasks.find { |t| t.id == id }
      # Unknown dependencies are treated as unsatisfiable: this surfaces
      # broken graphs as DeadlockError rather than silently running tasks
      # whose prerequisites don't exist.
      !!task&.done?
    end

    def run_parallel(tasks)
      tasks.each { |t| t.status = :running }

      threads = tasks.map do |task|
        Thread.new do
          Thread.current.report_on_exception = false
          [task, safe_invoke(task)]
        end
      end

      threads.map(&:value).each do |task, result|
        finalize(task, result)
      end
    end

    def run_sequential(tasks)
      tasks.each do |task|
        task.status = :running
        finalize(task, safe_invoke(task))
      end
    end

    def finalize(task, result)
      task.status = :done
      task.result = result
      @context.record_result(task.id, result)
    end

    def safe_invoke(task)
      @runner.call(task, @context)
    rescue StandardError => e
      "error: #{e.message}"
    end
  end
end
