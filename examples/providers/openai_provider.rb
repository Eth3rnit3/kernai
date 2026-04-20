# frozen_string_literal: true

# Legacy location of the OpenAI provider — kept as a thin alias so
# existing code and VCR tests that reference `Kernai::Examples::OpenaiProvider`
# keep working. Prefer `Kernai::Providers::Openai` in new code.
require 'kernai/providers/openai'

module Kernai
  module Examples
    OpenaiProvider = Kernai::Providers::Openai
  end
end
