# frozen_string_literal: true

# Scenario: Mixed local skill + MCP protocol (🟡)
#
# Validates that a single response from the LLM can interleave a local skill
# call AND an MCP protocol call, and that both are dispatched in the order
# the LLM emitted them with correct observability stamping on both rails.
#
# The agent must:
#   1. Discover both rails: /skills (local skill catalog) and /protocols (MCP)
#   2. Read a file from a real MCP filesystem server
#   3. Pass the file contents through a LOCAL Ruby skill that summarizes + counts
#   4. Return a final answer combining the summarizer's output with a fact from
#      the raw file that the skill does NOT surface (forcing the agent to have
#      actually seen the MCP result, not just the skill result)
#
# Failure modes:
#   - Agent uses only skills and never touches MCP
#   - Agent uses only MCP and invents the summarization numbers
#   - Agent skips /protocols discovery and assumes MCP isn't there
#
# Prerequisites:
#   - `gem install mcp_client`
#   - Node.js + npx
#
# Usage:
#   ruby scenarios/mcp_mixed_skill_and_protocol.rb

require 'fileutils'
require_relative 'harness'

# Independent sandbox so this scenario doesn't collide with mcp_filesystem_exploration.
MIXED_SANDBOX = File.expand_path('logs/mcp_mixed_sandbox', __dir__)
FileUtils.mkdir_p(MIXED_SANDBOX)
File.write(File.join(MIXED_SANDBOX, 'article.txt'), <<~TEXT)
  Kernai is a minimal Ruby framework for building AI agents.
  It uses a universal XML block protocol to orchestrate skills and external protocols.
  Sub-agents can be spawned declaratively via structured workflow plans.
  The secret codeword for this scenario is PELICAN.
  Agents remain fully observable through the recorder.
TEXT

Scenarios.define(
  'mcp_mixed_skill_and_protocol',
  description: 'Interleaves a local skill and an MCP tool call in the same agentic flow'
) do
  mcp_config(
    'servers' => {
      'docs' => {
        'transport' => 'stdio',
        'command' => 'npx',
        'args' => ['-y', '@modelcontextprotocol/server-filesystem', MIXED_SANDBOX]
      }
    }
  )

  # Explicitly allow both rails: the local skill catalog AND the MCP protocol.
  protocols [:mcp]

  skill(:summarize_text) do
    description 'Summarize a piece of text and report simple statistics. Pure local Ruby — does NOT have access to MCP.'
    input :text, String

    execute do |params|
      text = params[:text].to_s
      lines = text.lines.map(&:strip).reject(&:empty?)
      words = text.split(/\s+/).reject(&:empty?)
      longest = lines.max_by(&:length).to_s
      {
        line_count: lines.size,
        word_count: words.size,
        longest_line_length: longest.length,
        first_line: lines.first.to_s
      }.to_json
    end
  end

  article_abs_path = File.join(MIXED_SANDBOX, 'article.txt')

  instructions <<~PROMPT
    You are a research assistant that has access to BOTH local skills AND
    external protocols. They are distinct rails and you must use each for
    its proper purpose:
      - Local skills are Ruby functions that run in-process.
      - Protocols are external systems (e.g. filesystems, APIs) reached
        through a dedicated handler.

    Environment facts:
      - A text document lives at the absolute path: #{article_abs_path}
      - That document is only reachable through an external protocol — no
        local skill can read files from disk.
      - The protocol backend serving that path rejects relative paths.

    Your task:
      1. Obtain the raw text of the document at #{article_abs_path}.
      2. Produce structured statistics about it (line count, word count,
         longest line, first line). Your own reasoning CANNOT compute these
         reliably — there is a local skill designed exactly for this.
      3. Locate the secret codeword embedded in the raw document. It is a
         single uppercase word on a line of the form
         "The secret codeword for this scenario is <CODEWORD>.".
         The statistics skill intentionally hides this codeword — it is
         only visible in the raw document itself.

    Your final answer must include BOTH the statistics from the skill AND
    the secret codeword you found in the raw text.

    Evaluation rules:
      - Every statistic in your answer must come from the statistics skill.
      - The codeword in your answer must come from the raw document content,
        not from this prompt.
      - A correct answer requires using both rails — skill AND protocol —
        in the same run.
  PROMPT

  input "Read the document at #{article_abs_path}, summarize it, and report " \
        'the stats plus the secret codeword hidden inside.'
  max_steps 12
end
