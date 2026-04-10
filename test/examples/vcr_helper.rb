# frozen_string_literal: true

require_relative '../test_helper'
require 'vcr'
require 'webmock/minitest'

# Load example providers
require_relative '../../examples/providers/openai_provider'
require_relative '../../examples/providers/anthropic_provider'
require_relative '../../examples/providers/ollama_provider'

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path('cassettes', __dir__)
  c.hook_into :webmock

  # Recording must be explicit. Default is :none (replay only, CI-safe).
  # Merely having an API key in the local env is NOT enough to enable
  # recording — previous behavior silently mutated cassettes the first
  # time a test reached an un-recorded branch on a dev machine with
  # OLLAMA_API_KEY / OPENAI_API_KEY set.
  #
  #   VCR_RECORD=new   → :new_episodes (append missing interactions)
  #   VCR_RECORD=all   → :all (re-record everything from scratch)
  #   (unset)          → :none (replay only, fail on missing cassettes)
  record_mode = case ENV['VCR_RECORD']
                when 'all' then :all
                when 'new', 'new_episodes' then :new_episodes
                else :none
                end

  c.default_cassette_options = {
    record: record_mode,
    match_requests_on: %i[method uri]
  }

  # Filter sensitive data
  c.filter_sensitive_data('<OPENAI_API_KEY>') { ENV['OPENAI_API_KEY'] || 'test-key' }
  c.filter_sensitive_data('<ANTHROPIC_API_KEY>') { ENV['ANTHROPIC_API_KEY'] || 'test-key' }
  c.filter_sensitive_data('<OLLAMA_API_KEY>') { ENV['OLLAMA_API_KEY'] || 'test-key' }
end

BLOCK_INSTRUCTIONS = <<~PROMPT
  You MUST respond ONLY using XML blocks with this EXACT syntax:
  <block type="TYPE">content here</block>

  CRITICAL: The tag name is always "block" with a type attribute. Never use shorthand tags like <final> or <command>.

  Correct example:
  <block type="final">This is my answer.</block>

  Wrong (DO NOT use):
  <final>This is my answer.</final>

  Available types:
  - final: your final answer to the user
  - command: execute an action (requires name attribute, e.g. <block type="command" name="skill_name">params</block>)
  - plan: your reasoning before answering (optional)

  Always wrap your final answer in <block type="final">...</block>.
PROMPT
