require_relative "../test_helper"
require "vcr"
require "webmock/minitest"

# Load example providers
require_relative "../../examples/providers/openai_provider"
require_relative "../../examples/providers/anthropic_provider"

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path("cassettes", __dir__)
  c.hook_into :webmock
  record_mode = ENV["VCR_RECORD"] == "all" ? :all : :new_episodes
  c.default_cassette_options = {
    record: record_mode,
    match_requests_on: %i[method uri]
  }

  # Filter sensitive data
  c.filter_sensitive_data("<OPENAI_API_KEY>") { ENV["OPENAI_API_KEY"] || "test-key" }
  c.filter_sensitive_data("<ANTHROPIC_API_KEY>") { ENV["ANTHROPIC_API_KEY"] || "test-key" }
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
