# frozen_string_literal: true

# Legacy location of the Anthropic provider — kept as a thin alias so
# existing code and VCR tests that reference `Kernai::Examples::AnthropicProvider`
# keep working. Prefer `Kernai::Providers::Anthropic` in new code.
require 'kernai/providers/anthropic'

module Kernai
  module Examples
    AnthropicProvider = Kernai::Providers::Anthropic
  end
end
