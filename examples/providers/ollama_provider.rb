# frozen_string_literal: true

# Legacy location of the Ollama provider — kept as a thin alias so
# existing code and VCR tests that reference `Kernai::Examples::OllamaProvider`
# keep working. Prefer `Kernai::Providers::Ollama` in new code.
require 'kernai/providers/ollama'

module Kernai
  module Examples
    OllamaProvider = Kernai::Providers::Ollama
  end
end
