module Kernai
  module Parser
    BLOCK_PATTERN = /<block\s+type="([^"]+)"(?:\s+name="([^"]*)")?\s*>(.*?)<\/block>/m

    class << self
      def parse(text)
        blocks = []
        text_segments = []
        last_end = 0

        text.scan(BLOCK_PATTERN) do
          match = Regexp.last_match
          start_pos = match.begin(0)

          # Capture text before this block
          if start_pos > last_end
            segment = text[last_end...start_pos]
            text_segments << segment unless segment.strip.empty?
          end

          type = match[1]
          name = match[2]
          content = match[3]

          blocks << Block.new(type: type.to_sym, content: content, name: name)

          last_end = match.end(0)
        end

        # Capture trailing text after the last block
        if last_end < text.length
          segment = text[last_end..]
          text_segments << segment unless segment.strip.empty?
        end

        { blocks: blocks, text_segments: text_segments }
      end
    end
  end
end
