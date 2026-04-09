# frozen_string_literal: true

# Scenario: Cyclic plan must be rejected by Plan.parse (⚫)
#
# Plan.cyclic? does a DFS with tri-state marking; any back-edge makes
# Plan.parse return nil. The kernel must treat the cyclic block as
# informational only (no workflow execution, no deadlock), and the agent
# must recover on the next step.
#
# Expected behavior:
#   1. Agent emits a plan with tasks a <-> b <-> c (tight cycle).
#   2. Plan.parse returns nil → ctx.plan stays empty, no scheduler runs,
#      no DeadlockError is raised (that error is only for live graphs that
#      can't progress).
#   3. Agent recovers on step 2 with a corrected acyclic plan OR falls back
#      to direct skill calls to finish the task.
#   4. Final answer summarizes the two audit categories from the skill.
#
# Failure modes:
#   - Kernel attempts to run the cyclic plan and raises DeadlockError from
#     the scheduler (wrong layer — Plan.parse should have filtered it).
#   - Kernel infinite-loops trying to resolve dependencies.
#   - Agent keeps re-emitting the same cyclic plan and hits max_steps.
#
#   ruby scenarios/cyclic_plan_rejected.rb
#   ruby scenarios/cyclic_plan_rejected.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'cyclic_plan_rejected',
  description: 'Plan with a dependency cycle — Plan.parse must reject it and the agent must recover'
) do
  instructions <<~PROMPT
    You are a compliance auditor. On your FIRST turn, emit this plan EXACTLY
    (it contains an intentional cycle so we can verify the framework rejects
    cyclic graphs):

    <block type="plan">{"goal":"audit","strategy":"mixed","tasks":[
      {"id":"a","input":"run audit A","depends_on":["c"]},
      {"id":"b","input":"run audit B","depends_on":["a"]},
      {"id":"c","input":"run audit C","depends_on":["b"]}
    ]}</block>

    The framework should silently ignore this plan (Plan.parse returns nil
    for cycles). On your SECOND turn, once you notice nothing ran, fall
    back to calling the `audit_report` skill directly for both categories
    ("access_control" and "data_retention") and produce a <block type="final">
    summary listing the number of findings in each category.
  PROMPT

  skill(:audit_report) do
    description 'Fetch the latest audit report for a compliance category.'
    input :category, String

    execute do |params|
      cat = params[:category].to_s.downcase.strip
      data = {
        'access_control' => { category: 'access_control', findings: 4,
                              top: 'Shared service account still active for legacy ETL',
                              generated_at: '2026-04-09T06:00:00Z' },
        'data_retention' => { category: 'data_retention', findings: 2,
                              top: 'Customer export logs retained 730 days (policy: 365)',
                              generated_at: '2026-04-09T06:00:00Z' }
      }
      JSON.generate(data[cat] || { error: "Unknown category #{cat}" })
    end
  end

  input 'Give me the current compliance audit summary for access control and data retention.'
  max_steps 6
end
