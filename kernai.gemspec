# frozen_string_literal: true

require_relative 'lib/kernai/version'

Gem::Specification.new do |spec|
  spec.name          = 'kernai'
  spec.version       = Kernai::VERSION
  spec.authors       = ['Eth3rnit3']
  spec.email         = ['eth3rnit3@gmail.com']

  spec.summary       = 'A minimal, extensible AI agent kernel based on a universal structured block protocol'
  spec.description   = <<~DESC
    Kernai is an AI agent kernel based on a universal XML block protocol,
    enabling simple, dynamic, observable and fully controlled orchestration
    without external runtime dependencies. Ships with reference provider
    adapters for Anthropic, OpenAI and Ollama, native multimodal support,
    a workflow DAG scheduler, pluggable recorder sinks and an optional
    MCP (Model Context Protocol) bridge.
  DESC

  spec.homepage      = 'https://github.com/Eth3rnit3/kernai'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.2'

  spec.files = Dir[
    'lib/**/*.rb',
    'README.md',
    'CHANGELOG.md',
    'LICENSE'
  ]
  spec.require_paths = ['lib']

  spec.metadata['homepage_uri']          = spec.homepage
  spec.metadata['source_code_uri']       = "#{spec.homepage}/tree/v#{spec.version}"
  spec.metadata['changelog_uri']         = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['bug_tracker_uri']       = "#{spec.homepage}/issues"
  spec.metadata['documentation_uri']     = "#{spec.homepage}#readme"
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Push only to the public index. If the user later wants to publish to a
  # private gem server, they can override this at publish time.
  spec.metadata['allowed_push_host']     = 'https://rubygems.org'
end
