# frozen_string_literal: true

# Scenario: Deadlock from unknown dependency (⚫)
#
# Plan.parse prunes dependencies that don't exist in the task list
# (`prune_invalid_dependencies`). So an "unknown id" dep is stripped and
# will NOT deadlock — that branch is already covered. This scenario targets
# the OTHER deadlock path: a dep on a task that exists but will never
# finish because it itself depends on something that was pruned AND whose
# status we manually prevent from clearing.
#
# To reliably trigger TaskScheduler::DeadlockError without the cycle
# detector eating our plan, we use a subtle construction:
#   - task "t_ready" has no deps and should run fine
#   - task "t_orphan" depends on "t_ready" — also runs fine
#   - task "t_blocked" depends on a task id that is present but will
#     raise inside the skill. The runner catches errors and marks the
#     task as done with "error: ...", so strictly speaking this flows,
#     which means we actually want to test the HAPPY deadlock path:
#     a plan whose only task has a self-loop (filtered by prune) but
#     where we DON'T want a deadlock — so instead we test the user-visible
#     behavior where the agent's plan triggers a scheduler deadlock by
#     asking for work the scheduler can't make progress on.
#
# Simpler + more honest: instruct the LLM to create a plan with two tasks
# where BOTH list each other as deps (tight cycle). Plan.parse will reject
# it via cyclic? and return nil. We've covered that already in
# cyclic_plan_rejected.rb.
#
# To reach DeadlockError at the scheduler level, we need a graph where:
#   - Plan.parse accepts it (no cycles, only known ids).
#   - At runtime a task is stuck waiting for a peer that never completes.
# The only way a task "never completes" today is if the scheduler thread
# blocks forever. We can force that by having a skill `sleep forever`.
# But that's a DoS on tests.
#
# Instead, this scenario verifies the SAFER property: when the LLM tries to
# reference a non-existent task id, the pruner drops the dep and the task
# runs immediately with no dep context. The sub-agent must then notice its
# input is missing upstream data and surface the issue cleanly.
#
# Expected behavior:
#   1. Agent emits a plan with two tasks where "t_finalize" depends on
#      "t_ghost" (which does not exist in the task list).
#   2. Plan.parse prunes the dangling dep — the plan runs with t_finalize
#      having no deps.
#   3. The t_finalize sub-agent produces a final answer that ONLY relies on
#      the inputs it was given (i.e. it doesn't hallucinate the missing
#      upstream data).
#   4. Root agent's final answer explicitly calls out that the plan had a
#      pruned dependency and explains what was done.
#
# Failure modes:
#   - Scheduler raises DeadlockError because the pruner didn't run.
#   - Sub-agent fabricates upstream data that was never supplied.
#   - Root agent claims the workflow succeeded as originally designed.
#
#   ruby scenarios/deadlock_unknown_dep.rb
#   ruby scenarios/deadlock_unknown_dep.rb gpt-4.1 openai

require_relative 'harness'

Scenarios.define(
  'deadlock_unknown_dep',
  description: 'Plan references a non-existent task id — prune_invalid_dependencies must drop the dep cleanly'
) do
  instructions <<~PROMPT
    You are a release coordinator. On your FIRST turn, emit the following
    plan EXACTLY (note: "t_finalize" depends on "t_ghost" which does NOT
    exist in the task list — this is intentional, we are testing how the
    framework handles dangling deps):

    <block type="plan">{"goal":"release audit","strategy":"mixed","tasks":[
      {"id":"t_collect","input":"Use `release_manifest` skill to list files in v2026.4.0","parallel":true,"depends_on":[]},
      {"id":"t_finalize","input":"Summarize which files are new in v2026.4.0 compared to v2026.3.9","parallel":false,"depends_on":["t_ghost"]}
    ]}</block>

    After the workflow result comes back, inspect it. If "t_finalize"
    received no upstream data (because t_ghost never existed), your final
    answer must explicitly mention:
      - the plan had a dangling dependency on "t_ghost"
      - the framework pruned it and ran t_finalize without upstream input
      - what the collected manifest contained

    Never fabricate data that wasn't in the sub-agent results.
  PROMPT

  skill(:release_manifest) do
    description 'Fetch the file manifest for a release tag.'
    input :tag, String

    execute do |params|
      tag = params[:tag].to_s.strip
      manifests = {
        'v2026.4.0' => {
          tag: 'v2026.4.0',
          files: ['lib/core/router.rb', 'lib/core/auth.rb', 'lib/core/billing.rb', 'lib/feature/ai_copilot.rb'],
          generated_at: '2026-04-09T10:00:00Z'
        }
      }
      JSON.generate(manifests[tag] || { error: "Unknown tag #{tag}" })
    end
  end

  input 'Run the release audit plan for v2026.4.0.'
  max_steps 8
end
