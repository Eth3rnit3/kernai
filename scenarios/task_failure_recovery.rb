# frozen_string_literal: true

# Scenario: Task failure recovery (⚫)
#
# One of the skills intentionally raises. TaskScheduler#safe_invoke catches
# standard errors and records the result as "error: <msg>", so the task
# still completes (status: :done) from the scheduler's perspective. The
# aggregator sub-agent depends on the failing task AND on a healthy peer,
# so it must produce a degraded-mode answer that honors the healthy peer's
# data and surfaces the failure.
#
# Expected plan:
#   t_health_prod   (parallel: true,  depends_on: [])  — succeeds
#   t_health_stage  (parallel: true,  depends_on: [])  — RAISES (skill throws)
#   t_report        (parallel: false, depends_on: [t_health_prod, t_health_stage])
#
# Expected behavior:
#   1. Both parallel tasks run; t_health_stage comes back as "error: <msg>".
#   2. t_report receives BOTH deps injected as result blocks, sees the
#      "error:" string on the stage one, and produces a degraded report.
#   3. Root agent's final answer:
#       - cites prod metrics accurately
#       - explicitly states that staging health could not be retrieved
#         and why
#       - does NOT fabricate staging numbers
#
# Failure modes:
#   - Scheduler re-raises and crashes the workflow.
#   - Aggregator fabricates stage numbers to fill the hole.
#   - Final answer omits the error entirely and presents a half-report as
#     if everything was fine.
#
#   ruby scenarios/task_failure_recovery.rb
#   ruby scenarios/task_failure_recovery.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'task_failure_recovery',
  description: 'One parallel task raises — aggregator must see "error:" and produce a degraded report'
) do
  instructions <<~PROMPT
    You are a platform SRE. The user wants a health report for prod and
    staging. You MUST emit a plan with three tasks:

      t_health_prod   (parallel: true,  depends_on: [])
        -> call `service_health` with env="prod"
      t_health_stage  (parallel: true,  depends_on: [])
        -> call `service_health` with env="stage"
      t_report        (parallel: false, depends_on: [t_health_prod, t_health_stage])
        -> fuse both results into a written report

    When task results come back, if any dep contains a string starting
    with "error:", treat that environment as UNAVAILABLE. Do not invent
    metrics. Your final answer must state:
      - prod status + error rate + p99
      - staging status (or "unavailable — <reason>")
      - overall recommendation
  PROMPT

  skill(:service_health) do
    description 'Fetch health metrics for an environment. Raises on unreachable envs.'
    input :env, String

    execute do |params|
      env = params[:env].to_s.downcase.strip
      case env
      when 'prod'
        JSON.generate(
          env: 'prod',
          status: 'healthy',
          error_rate_pct: 0.12,
          p99_ms: 184,
          checked_at: '2026-04-09T12:30:00Z'
        )
      when 'stage', 'staging'
        # Deterministic failure: the staging health endpoint is down today.
        raise 'staging health endpoint unreachable (ECONNREFUSED prom-stage:9090)'
      else
        JSON.generate(error: "Unknown env #{env}")
      end
    end
  end

  input 'Give me a health report for prod and staging right now.'
  max_steps 8
end
