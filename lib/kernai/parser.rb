# frozen_string_literal: true

module Kernai
  module Parser
    # Canonical: <block type="TYPE" name="NAME">content</block>
    BLOCK_PATTERN = %r{<block\s+type="([^"]+)"(?:\s+name="([^"]*)")?\s*>(.*?)</block>}m

    # Shorthand: <TYPE name="NAME">content</TYPE> (e.g. <final>answer</final>)
    SHORTHAND_TYPES = Block::TYPES.map(&:to_s).join('|')
    SHORTHAND_PATTERN = %r{<(#{SHORTHAND_TYPES})(?:\s+name="([^"]*)")?\s*>(.*?)</\1>}m

    class << self
      # Scans the response text once and weaves blocks and text
      # segments back in source order. The method is linear but touches
      # a lot of locals (matches, positions, segments) which drives AbcSize
      # up without adding real complexity.
      # rubocop:disable Metrics/AbcSize
      def parse(text)
        blocks = []
        text_segments = []

        # Find all matches from both patterns with their positions
        matches = []

        text.scan(BLOCK_PATTERN) do
          m = Regexp.last_match
          matches << { pos: m.begin(0), end_pos: m.end(0), type: m[1], name: m[2], content: m[3] }
        end

        text.scan(SHORTHAND_PATTERN) do
          m = Regexp.last_match
          # Skip if this region overlaps with an already-found canonical block
          next if matches.any? { |existing| m.begin(0) >= existing[:pos] && m.begin(0) < existing[:end_pos] }

          matches << { pos: m.begin(0), end_pos: m.end(0), type: m[1], name: m[2], content: m[3] }
        end

        matches.sort_by! { |m| m[:pos] }

        last_end = 0
        matches.each do |m|
          if m[:pos] > last_end
            segment = text[last_end...m[:pos]]
            text_segments << segment unless segment.strip.empty?
          end

          blocks << Block.new(type: m[:type].to_sym, content: m[:content], name: m[:name])
          last_end = m[:end_pos]
        end

        if last_end < text.length
          segment = text[last_end..]
          text_segments << segment unless segment.strip.empty?
        end

        { blocks: blocks, text_segments: text_segments }
      end
      # rubocop:enable Metrics/AbcSize
    end
  end
end
