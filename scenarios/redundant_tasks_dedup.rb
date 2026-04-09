# frozen_string_literal: true

# Scenario: Redundant tasks in a plan (⚫)
#
# An agent that doesn't reason carefully will sometimes emit a plan where
# several tasks do the exact same thing (same input, same skill). The
# scheduler dutifully runs all of them — there's no built-in dedup. This
# scenario checks that:
#   - Parallel duplicates really run in parallel (no accidental mutex).
#   - Each duplicate gets its own isolated sub-context.
#   - The root agent notices the redundancy in task_results and reports
#     the underlying metric ONCE, not N times.
#
# This is an explicit "quality of reasoning" test: the plan is wasteful
# on purpose, and the root agent must still produce a single, coherent
# number rather than "the KPI is 42, 42, 42".
#
# Expected behavior:
#   1. Root agent emits a plan with THREE identical tasks (all calling
#      `kpi_lookup` with metric="weekly_active_users", parallel: true).
#   2. Scheduler runs all three concurrently.
#   3. Root agent dedupes in its final answer and reports a single value.
#
# Failure modes:
#   - Agent reports the KPI three times in its final answer.
#   - Scheduler serializes the duplicates (should be parallel because each
#     task has parallel: true).
#   - The skill's deterministic value differs between calls (would mean
#     state leaked between sub-contexts).
#
#   ruby scenarios/redundant_tasks_dedup.rb
#   ruby scenarios/redundant_tasks_dedup.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'redundant_tasks_dedup',
  description: 'Plan contains three identical parallel tasks — final answer must dedupe'
) do
  instructions <<~PROMPT
    You are a growth analyst. The user wants the weekly active user KPI.
    To stress the workflow scheduler, emit a plan with THREE identical
    parallel tasks (t_kpi_1, t_kpi_2, t_kpi_3), each calling `kpi_lookup`
    with metric="weekly_active_users". Use strategy "parallel".

    When the task results come back, they will contain the same value
    three times (the skill is deterministic). Your final answer must:
      - report the KPI value EXACTLY ONCE
      - explicitly note that the plan had redundant tasks and that you
        deduplicated them in the summary
      - state the data freshness timestamp
  PROMPT

  skill(:kpi_lookup) do
    description 'Return a KPI value. Deterministic across calls.'
    input :metric, String

    execute do |_params|
      # Sleep to make the parallel execution observable in timing logs.
      sleep 0.2
      JSON.generate(
        metric: 'weekly_active_users',
        value: 184_203,
        as_of: '2026-04-07T00:00:00Z',
        source: 'analytics.rollups.wau'
      )
    end
  end

  input 'What is our current weekly active users KPI?'
  max_steps 8
end
