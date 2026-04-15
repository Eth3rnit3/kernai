# frozen_string_literal: true

# Error base is declared BEFORE the internal requires so that any
# component loaded below can subclass Kernai::Error safely. Specific
# well-known error classes are declared here too, and are the ones the
# end user typically rescues.
module Kernai
  class Error < StandardError; end
  class SkillNotFoundError < Error; end
  class SkillNotAllowedError < Error; end
  class CredentialMissingError < Error; end
  class MaxStepsReachedError < Error; end
  class ProviderError < Error; end
end

require_relative 'kernai/version'
require_relative 'kernai/config'
require_relative 'kernai/credential_resolver'
require_relative 'kernai/skill_context'
require_relative 'kernai/logger'
require_relative 'kernai/media'
require_relative 'kernai/media_store'
require_relative 'kernai/model'
require_relative 'kernai/message'
require_relative 'kernai/block'
require_relative 'kernai/parser'
require_relative 'kernai/stream_parser'
require_relative 'kernai/skill'
require_relative 'kernai/skill_result'
require_relative 'kernai/protocol'
require_relative 'kernai/llm_response'
require_relative 'kernai/provider'
require_relative 'kernai/instruction_builder'
require_relative 'kernai/recorder'
require_relative 'kernai/plan'
require_relative 'kernai/context'
require_relative 'kernai/task_scheduler'
require_relative 'kernai/agent'
require_relative 'kernai/kernel'
require_relative 'kernai/mock/provider'

module Kernai
  def self.config
    @config ||= Config.new
  end

  def self.configure
    yield config
  end

  def self.logger
    config.logger
  end

  def self.reset!
    @config = Config.new
    Skill.reset!
    Protocol.reset!
  end
end
