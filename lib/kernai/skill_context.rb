# frozen_string_literal: true

module Kernai
  # Passed as the second argument to a skill's execute block. Exposes
  # `credential(:key)` and `config(:key)` lookups that go through the
  # resolvers configured on Kernai.config.
  #
  # Validation of required credentials happens lazily at access time,
  # not at skill registration, so a skill can be defined in a context
  # where its credentials aren't yet set (tests, partial scenarios).
  # Missing required credentials raise Kernai::CredentialMissingError
  # only when the skill actually tries to read them.
  class SkillContext
    def initialize(skill, credential_resolver: nil, config_resolver: nil)
      @skill = skill
      @credential_resolver = credential_resolver
      @config_resolver = config_resolver
      @cache = {}
    end

    def credential(key)
      key = key.to_sym
      spec = @skill.credentials[key]
      unless spec
        raise ArgumentError,
              "Skill '#{@skill.name}' did not declare credential '#{key}'. " \
              "Declared: #{@skill.credentials.keys.inspect}"
      end

      cache_key = [:credential, key]
      return @cache[cache_key] if @cache.key?(cache_key)

      resolver = @credential_resolver || Kernai.config.credential_resolver
      value = resolver.resolve(@skill.name, key)

      if value.nil? && spec[:required]
        raise Kernai::CredentialMissingError,
              "Missing required credential '#{key}' for skill '#{@skill.name}'. " \
              "Configure it via the host (e.g. kernai-shell `/skill-config`) or " \
              "set KERNAI_SKILL_#{@skill.name.to_s.upcase}_#{key.to_s.upcase}."
      end

      @cache[cache_key] = value
    end

    def config(key)
      key = key.to_sym
      spec = @skill.configs[key]
      unless spec
        raise ArgumentError,
              "Skill '#{@skill.name}' did not declare config '#{key}'. " \
              "Declared: #{@skill.configs.keys.inspect}"
      end

      cache_key = [:config, key]
      return @cache[cache_key] if @cache.key?(cache_key)

      resolver = @config_resolver || Kernai.config.config_resolver
      raw = resolver.resolve(@skill.name, key)
      value = raw.nil? ? spec[:default] : coerce(raw, spec[:type])
      @cache[cache_key] = value
    end

    private

    # Resolvers return strings (from ENV or files). Configs declare a
    # type, so coerce at read time rather than forcing every caller
    # to parse `"10"` into an Integer.
    def coerce(value, type)
      return value if type.nil? || value.is_a?(type)

      case type.name
      when 'Integer' then Integer(value)
      when 'Float'   then Float(value)
      when 'String'  then value.to_s
      when 'TrueClass', 'FalseClass'
        %w[1 true yes on].include?(value.to_s.downcase)
      else value
      end
    end
  end
end
