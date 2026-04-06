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
  You must respond using XML blocks of the form:
  <block type="TYPE">...</block>

  Available types:
  - command: execute an action (requires name attribute for skill)
  - final: your final answer to the user
  - plan: your reasoning (optional)

  When you have a final answer, wrap it in a final block.
  Always respond with at least one block.
PROMPT
