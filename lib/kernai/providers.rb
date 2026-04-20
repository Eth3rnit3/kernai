# frozen_string_literal: true

# Convenience require that pulls in every bundled provider adapter.
# Application code that needs all three can simply do:
#
#   require 'kernai/providers'
#
# Then instantiate `Kernai::Providers::Anthropic`, `Kernai::Providers::Openai`,
# or `Kernai::Providers::Ollama` directly.
require_relative 'providers/anthropic'
require_relative 'providers/openai'
require_relative 'providers/ollama'
