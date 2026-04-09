# frozen_string_literal: true

# Scenario: MCP filesystem exploration (🟡)
#
# Exercises the full exploratory pattern against a REAL public MCP server
# (@modelcontextprotocol/server-filesystem, spawned through npx).
#
# Expected behavior:
#   1. Agent discovers the MCP protocol via /protocols.
#   2. Agent lists configured MCP servers (servers/list).
#   3. Agent lists tools on the filesystem server (tools/list).
#   4. Agent inspects at least one tool's schema (tools/describe) before calling it.
#   5. Agent reads or lists files inside the sandbox directory (tools/call).
#   6. Agent returns a <block type="final"> summarizing what it found.
#
# Failure modes:
#   - Agent hallucinates the directory contents without ever calling tools/call.
#   - Agent skips discovery and tries to call a made-up tool name.
#   - Agent loops re-listing tools forever.
#
# Prerequisites:
#   - `gem install mcp_client` (optional dependency; harness skips gracefully if missing)
#   - Node.js + npx (the server binary is spawned via `npx -y @modelcontextprotocol/server-filesystem`)
#
# Usage:
#   ruby scenarios/mcp_filesystem_exploration.rb
#   ruby scenarios/mcp_filesystem_exploration.rb gpt-4.1 openai

require 'fileutils'
require_relative 'harness'

# Prepare an isolated sandbox so the scenario is fully reproducible and the
# MCP server only sees files we put there on purpose.
SANDBOX = File.expand_path('logs/mcp_fs_sandbox', __dir__)
FileUtils.mkdir_p(SANDBOX)
File.write(File.join(SANDBOX, 'readme.txt'), <<~TEXT)
  Kernai MCP filesystem scenario sandbox.
  The agent should discover this file by calling tools/list then tools/call.
  Magic number: 42
TEXT
File.write(File.join(SANDBOX, 'notes.md'), "# Notes\n\n- first item\n- second item\n")

Scenarios.define(
  'mcp_filesystem_exploration',
  description: 'Agent explores a real filesystem MCP server end to end via the exploratory pattern'
) do
  mcp_config(
    'servers' => {
      'filesystem' => {
        'transport' => 'stdio',
        'command' => 'npx',
        'args' => ['-y', '@modelcontextprotocol/server-filesystem', SANDBOX]
      }
    }
  )

  protocols [:mcp]

  instructions <<~PROMPT
    You are a research agent. You have zero prior knowledge of any filesystem
    contents — you must discover everything through your tools.

    Environment facts (you cannot infer these, they are given):
      - A filesystem you can read lives at the absolute path: #{SANDBOX}
      - This filesystem is exposed through an MCP protocol you have access to.
      - The filesystem backend rejects relative paths; always use absolute
        paths rooted at #{SANDBOX}.

    Your task:
      Tell me exhaustively what files the sandbox contains and, if any file
      contains a line of the form "Magic number: <VALUE>", quote that line
      verbatim in your final answer.

    Evaluation rules:
      - Every factual claim in your final answer must be grounded in an
        actual tool result you received, not guessed or paraphrased.
      - If a tool call fails, adapt and try a different approach — do not
        abandon the task or invent content.
  PROMPT

  input 'Explore the sandbox directory made available via the MCP filesystem server ' \
        'and tell me what files it contains and what the magic number is.'

  max_steps 12
end
