# frozen_string_literal: true

module Kernai
  class Config
    attr_accessor :debug, :default_provider, :allowed_skills, :recorder

    def initialize
      @debug = false
      @default_provider = nil
      @allowed_skills = nil
      @logger = nil
      @recorder = nil
      @credential_resolver = nil
      @config_resolver = nil
    end

    def logger
      @logger ||= Kernai::Logger.new
    end

    # Lazy defaults so `Kernai::Config` can be required before the
    # resolver classes, and so hosts can override either one without
    # touching the other. ENV-backed defaults keep kernai usable as a
    # standalone gem.
    def credential_resolver
      @credential_resolver ||= Kernai::EnvResolver.new
    end

    def config_resolver
      @config_resolver ||= Kernai::EnvConfigResolver.new
    end

    attr_writer :logger, :credential_resolver, :config_resolver
  end
end
