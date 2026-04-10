# frozen_string_literal: true

module Kernai
  # Per-execution bag of Media objects keyed by id. Lives on the Context so
  # parent and child agents (spawned through workflows) share the same
  # store — a child can look up a media the parent produced, and a skill
  # can resolve a media by id without having to thread the object through
  # every intermediate message.
  class MediaStore
    def initialize
      @store = {}
      @mutex = Mutex.new
    end

    def put(media)
      raise ArgumentError, 'expected a Kernai::Media' unless media.is_a?(Media)

      @mutex.synchronize { @store[media.id] = media }
      media
    end

    def fetch(id)
      @mutex.synchronize { @store[id] }
    end

    def each(&block)
      @mutex.synchronize { @store.values.dup }.each(&block)
    end

    def size
      @mutex.synchronize { @store.size }
    end

    def empty?
      size.zero?
    end
  end
end
