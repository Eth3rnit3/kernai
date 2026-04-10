# frozen_string_literal: true

require_relative 'lib/kernai/version'

Gem::Specification.new do |spec|
  spec.name          = 'kernai'
  spec.version       = Kernai::VERSION
  spec.authors       = ['Eth3rnit3']
  spec.summary       = 'A minimal, extensible AI agent kernel based on a universal structured block protocol'
  spec.description   = <<~DESC
    Kernai is an AI agent kernel based on a universal block protocol,
    enabling simple, dynamic, observable and fully controlled
    orchestration without external dependencies.
  DESC
  spec.homepage      = 'https://github.com/Eth3rnit3/kernai'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.2'

  spec.files         = Dir['lib/**/*.rb']
  spec.require_paths = ['lib']

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
end
