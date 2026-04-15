# frozen_string_literal: true

module Kernai
  # Credentials and non-secret configs are declared by skills but resolved
  # by the host. Kernai ships two default resolvers (ENV-based) so the gem
  # is usable standalone; hosts like kernai-shell can swap them for chains
  # that read from sidecar files, keyrings, etc.
  #
  # Contract: resolve(skill_name, key) must return a String or nil. It
  # must never raise — the SkillContext turns a nil into a
  # CredentialMissingError only when the declaration was `required: true`.
  module CredentialResolver
    def resolve(_skill_name, _key)
      raise NotImplementedError
    end
  end

  # Looks up credentials in the environment under a scoped name:
  #   KERNAI_SKILL_<SKILL>_<KEY>
  # The scoped prefix is deliberate — a bare fallback to ENV[KEY] would
  # let unrelated process env leak into a skill and break the "agent
  # never sees secrets" guarantee when combined with a careless host.
  class EnvResolver
    include CredentialResolver

    def resolve(skill_name, key)
      ENV[env_key(skill_name, key)]
    end

    private

    def env_key(skill_name, key)
      "KERNAI_SKILL_#{skill_name.to_s.upcase}_#{key.to_s.upcase}"
    end
  end

  # Mirror of EnvResolver for non-secret config values. Kept as a
  # separate class so hosts can plug a file-backed config resolver
  # without touching credential handling.
  class EnvConfigResolver
    include CredentialResolver

    def resolve(skill_name, key)
      ENV["KERNAI_SKILL_#{skill_name.to_s.upcase}_#{key.to_s.upcase}"]
    end
  end

  # In-memory resolver for tests and scenarios. Accepts either a flat
  # hash keyed by symbol key (applies to all skills) or a nested hash
  # keyed by skill name then key.
  class HashResolver
    include CredentialResolver

    def initialize(data = {})
      @data = data
    end

    def resolve(skill_name, key)
      skill_scope = @data[skill_name.to_sym] || @data[skill_name.to_s]
      if skill_scope.is_a?(Hash)
        value = skill_scope[key.to_sym] || skill_scope[key.to_s]
        return value.to_s unless value.nil?
      end
      value = @data[key.to_sym] || @data[key.to_s]
      value.nil? ? nil : value.to_s
    end
  end
end
