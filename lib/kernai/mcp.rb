# frozen_string_literal: true

require 'json'
require 'yaml'

require_relative '../kernai' unless defined?(Kernai::Protocol)

module Kernai
  # Optional MCP (Model Context Protocol) adapter.
  #
  # Kernai's core stays fully protocol-agnostic. This file is loaded only
  # when the user explicitly `require 'kernai/mcp'` — at which point we
  # pull in the `mcp_client` gem (soft dependency) and register a handler
  # for the `:mcp` block type via Kernai::Protocol.
  #
  # The agent then speaks MCP's native verbs directly:
  #
  #   <block type="mcp">{"method":"tools/list","params":{"server":"fs"}}</block>
  #
  # There is no Kernai-invented wrapping around MCP primitives: method
  # names come from the MCP spec, plus one Kernai extension (`servers/list`)
  # that exposes the multiplexing layer the adapter adds on top.
  module MCP
    class ConfigError < StandardError; end
    class DependencyMissingError < StandardError; end

    MCP_DOCUMENTATION = <<~DOC
      MCP (Model Context Protocol) external access.

      ## Two vocabularies — do not confuse them

      There are exactly TWO kinds of names you will encounter, and they
      live in different layers:

      1. PROTOCOL METHODS — a fixed, closed set defined by the MCP spec
         (plus one Kernai extension). These go in the "method" field of
         your request. You cannot invent new ones.

      2. TOOL NAMES — dynamic, server-specific identifiers like
         "read_file", "list_directory", "search_files", etc. Each MCP
         server publishes its own catalog. Tool names are NOT protocol
         methods. You CANNOT use a tool name in the "method" field.

      To invoke a tool you always go through the protocol method
      `tools/call`, passing the tool name in `params.name`. There is no
      other entry point for invoking tools. Ever.

      ## Request shape

      Emit a <block type="mcp"> whose content is a JSON request:
        {"method":"<PROTOCOL_METHOD>","params":{...}}

      ## The complete, closed set of PROTOCOL METHODS

        servers/list                                        [Kernai ext] list configured MCP servers
        tools/list     {"server":"..."}                     list tools on a server (omit server to list all)
        tools/describe {"server":"...","name":"..."}        full JSON schema for one tool
        tools/call     {"server":"...","name":"...","arguments":{...}}
        resources/list {"server":"..."}                     list resources (server optional)
        resources/read {"server":"...","uri":"..."}         read a resource by URI
        prompts/list   {"server":"..."}                     list prompts (server optional)
        prompts/get    {"server":"...","name":"...","arguments":{...}}

      If a "method" value is not in this list, the request is rejected —
      including every tool name you see in tools/list output.

      ## Worked example: calling a tool named "list_directory"

      WRONG (tool name treated as a protocol method — rejected):
        <block type="mcp">{"method":"list_directory","params":{"path":"/tmp"}}</block>

      RIGHT (protocol method tools/call, tool name in params.name):
        <block type="mcp">{"method":"tools/call","params":{"server":"filesystem","name":"list_directory","arguments":{"path":"/tmp"}}}</block>

      The same pattern applies to every tool you discover, regardless of
      the server.

      ## Responses and errors

      Responses come back in <block type="result" name="mcp">.
      Errors come back in <block type="error" name="mcp">.

      ## Typical exploratory flow

      1. servers/list    — discover what's available
      2. tools/list      — see the tools on a specific server
      3. tools/describe  — inspect a tool's input schema before calling it
      4. tools/call      — execute the tool (this is the ONLY way to invoke it)

      ## Protocols vs skills

      Protocols are distinct from skills: skills are local Ruby callables
      invoked via <block type="command" name="...">. Protocols are external
      systems invoked via their own block type (here: <block type="mcp">).
    DOC

    # Adapter owns one MCPClient::Client and the mapping from MCP method
    # names to client operations. It is instantiated by MCP.load / MCP.setup
    # and held as a module-level singleton so Kernai::Protocol.register can
    # reference a stable handler.
    class Adapter
      attr_reader :client, :server_names

      # @param config [Hash] MCP config hash (same shape as the YAML file).
      # @param client [Object, nil] Optional pre-built client (must quack
      #   like MCPClient::Client: list_tools, call_tool, list_resources,
      #   read_resource, list_prompts, get_prompt, cleanup). When nil the
      #   adapter builds a real client from the upstream gem. Injection is
      #   primarily meant for tests, but advanced users can also pass a
      #   pre-configured client with custom middleware or transports.
      def initialize(config, client: nil)
        @config = config
        @server_names = config.fetch('servers').keys.map(&:to_s)
        if client
          @client = client
        else
          require_mcp_client!
          @client = build_client(config)
        end
      end

      # Entry point registered into Kernai::Protocol. Receives the raw
      # <block type="mcp"> block and returns a String payload (or raises,
      # in which case the kernel wraps it as an error block).
      def handle(block, _ctx)
        req = parse_request(block.content)
        dispatch(req)
      end

      def shutdown
        @client&.cleanup
      rescue StandardError
        # Best-effort: shutdown is typically called from at_exit, we must
        # not raise out of it.
        nil
      end

      private

      def require_mcp_client!
        # base64 is no longer part of Ruby's default gems since 3.4, and the
        # upstream `ruby-mcp-client` gem pulls it in internally without
        # declaring it as a runtime dependency. Require it first so the
        # failure mode stays readable: either base64 loads cleanly, or we
        # raise a specific error pointing the user at the fix.
        begin
          require 'base64'
        rescue LoadError => e
          raise DependencyMissingError,
                'Kernai::MCP needs the `base64` gem (Ruby >= 3.4 removed it from the stdlib ' \
                "and ruby-mcp-client uses it internally). Add `gem \"base64\"` to your Gemfile. (#{e.message})"
        end

        begin
          require 'mcp_client'
        rescue LoadError => e
          # Distinguish "the gem itself is missing" from "the gem is there
          # but one of its own dependencies failed to load".
          if e.message.include?('mcp_client') && !e.message.include?('mcp_client/')
            raise DependencyMissingError,
                  "Kernai::MCP requires the 'ruby-mcp-client' gem. " \
                  "Add `gem \"ruby-mcp-client\"` to your Gemfile. (#{e.message})"
          end

          raise DependencyMissingError,
                'Kernai::MCP could not load the MCP client — one of its transitive dependencies is missing. ' \
                "Resolve the underlying require failure and retry. (#{e.message})"
        end
      end

      def parse_request(content)
        text = content.to_s.strip
        raise ArgumentError, 'empty MCP request' if text.empty?

        parsed = JSON.parse(text)
        raise ArgumentError, 'MCP request must be a JSON object' unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid MCP request JSON: #{e.message}"
      end

      def dispatch(req)
        method = req['method'].to_s
        params = req['params'].is_a?(Hash) ? req['params'] : {}

        case method
        when 'servers/list'    then JSON.generate(@server_names)
        when 'tools/list'      then JSON.generate(list_tools(params['server']).map { |t| summarize_tool(t) })
        when 'tools/describe'  then JSON.generate(describe_tool(params))
        when 'tools/call'      then call_tool(params)
        when 'resources/list'  then JSON.generate(list_resources(params['server']).map { |r| summarize_resource(r) })
        when 'resources/read'  then read_resource(params)
        when 'prompts/list'    then JSON.generate(list_prompts(params['server']).map { |p| summarize_prompt(p) })
        when 'prompts/get'     then get_prompt(params)
        when '', nil           then raise ArgumentError, 'MCP request missing method'
        else raise ArgumentError, unknown_method_message(method, params)
        end
      end

      # Craft a helpful error message when the LLM uses an unknown "method"
      # value. The most common mistake is treating a tool name (e.g.
      # `list_directory`) as if it were a protocol method. We catch that
      # category error explicitly and point the agent to the correct
      # `tools/call` form so it can recover on its next turn instead of
      # looping through variations of the same wrong shape.
      def unknown_method_message(method, params)
        match = find_tool_by_name(method)
        return "unknown MCP method: #{method}" unless match

        tool, server_name = match
        example = JSON.generate(
          method: 'tools/call',
          params: {
            server: server_name,
            name: safe_attr(tool, :name),
            arguments: params.reject { |k, _| %w[server name].include?(k) }
          }
        )
        "unknown MCP method: #{method}. " \
          'It looks like a TOOL NAME, not a protocol method. ' \
          "To invoke a tool, use `tools/call` — e.g. #{example}"
      end

      # Returns [tool, server_name] for the first tool across any server
      # whose name matches `candidate`, or nil when no match is found.
      # Defensive: any upstream failure (transport issues, empty catalog)
      # degrades cleanly to "no suggestion" so we never mask the original
      # unknown-method error with a secondary one.
      def find_tool_by_name(candidate)
        all = @client.list_tools
        tool = all.find { |t| safe_attr(t, :name).to_s == candidate.to_s }
        return nil unless tool

        [tool, tool_server_name(tool)]
      rescue StandardError
        nil
      end

      # --- tools ---

      def list_tools(server)
        all = @client.list_tools
        return all if server.nil? || server.to_s.empty?

        filter_by_server(all, server)
      end

      def summarize_tool(tool)
        {
          name: safe_attr(tool, :name),
          description: safe_attr(tool, :description),
          server: tool_server_name(tool)
        }
      end

      def describe_tool(params)
        server = params['server']
        name = params.fetch('name') { raise ArgumentError, 'tools/describe requires params.name' }
        tool = list_tools(server).find { |t| safe_attr(t, :name) == name }
        raise ArgumentError, "tool not found: #{name}#{server ? " (server=#{server})" : ''}" unless tool

        {
          name: safe_attr(tool, :name),
          description: safe_attr(tool, :description),
          server: tool_server_name(tool),
          input_schema: safe_attr(tool, :schema),
          output_schema: safe_attr(tool, :output_schema),
          annotations: safe_attr(tool, :annotations)
        }.compact
      end

      def call_tool(params)
        name = params.fetch('name') { raise ArgumentError, 'tools/call requires params.name' }
        server = params['server']
        arguments = params['arguments'].is_a?(Hash) ? params['arguments'] : {}

        result = if server
                   @client.call_tool(name, arguments, server: server)
                 else
                   @client.call_tool(name, arguments)
                 end
        to_text(result)
      end

      # --- resources ---

      def list_resources(server)
        all = @client.list_resources
        return all if server.nil? || server.to_s.empty?

        filter_by_server(all, server)
      end

      def summarize_resource(resource)
        {
          uri: safe_attr(resource, :uri),
          name: safe_attr(resource, :name),
          description: safe_attr(resource, :description),
          mime_type: safe_attr(resource, :mime_type) || safe_attr(resource, :mimeType),
          server: tool_server_name(resource)
        }.compact
      end

      def read_resource(params)
        uri = params.fetch('uri') { raise ArgumentError, 'resources/read requires params.uri' }
        server = params['server']

        result = if server
                   @client.read_resource(uri, server: server)
                 else
                   @client.read_resource(uri)
                 end
        to_text(result)
      end

      # --- prompts ---

      def list_prompts(server)
        all = @client.list_prompts
        return all if server.nil? || server.to_s.empty?

        filter_by_server(all, server)
      end

      def summarize_prompt(prompt)
        {
          name: safe_attr(prompt, :name),
          description: safe_attr(prompt, :description),
          arguments: safe_attr(prompt, :arguments),
          server: tool_server_name(prompt)
        }.compact
      end

      def get_prompt(params)
        name = params.fetch('name') { raise ArgumentError, 'prompts/get requires params.name' }
        server = params['server']
        arguments = params['arguments'].is_a?(Hash) ? params['arguments'] : {}

        result = if server
                   @client.get_prompt(name, arguments, server: server)
                 else
                   @client.get_prompt(name, arguments)
                 end
        to_text(result)
      end

      # --- helpers ---

      # Many MCP objects expose `.server` pointing at a ServerBase with
      # `.name`. This helper tolerates missing attributes gracefully.
      def tool_server_name(obj)
        srv = safe_attr(obj, :server)
        return nil unless srv

        safe_attr(srv, :name) || srv.to_s
      end

      def filter_by_server(collection, server)
        server_str = server.to_s
        collection.select { |obj| tool_server_name(obj).to_s == server_str }
      end

      def safe_attr(obj, attr)
        return obj[attr.to_s] if obj.is_a?(Hash) && obj.key?(attr.to_s)
        return obj[attr] if obj.is_a?(Hash) && obj.key?(attr)
        return nil unless obj.respond_to?(attr)

        obj.public_send(attr)
      rescue StandardError
        nil
      end

      # v1 policy: protocol block results are text. Any non-text payload
      # (image, binary resource, structured content) is flattened to text
      # with an observable marker so the LLM sees something meaningful and
      # binaries never leak into the block stream.
      def to_text(result)
        return '' if result.nil?

        case result
        when String then result
        when Array  then result.map { |item| content_item_to_text(item) }.join("\n")
        when Hash   then hash_to_text(result)
        else
          if result.respond_to?(:to_h)
            hash_to_text(result.to_h)
          else
            result.to_s
          end
        end
      end

      def hash_to_text(hash)
        stringified = hash.transform_keys(&:to_s)
        if stringified['content'].is_a?(Array)
          stringified['content'].map { |item| content_item_to_text(item) }.join("\n")
        elsif stringified['type'] == 'text'
          stringified['text'].to_s
        else
          JSON.generate(stringified)
        end
      end

      def content_item_to_text(item)
        return item if item.is_a?(String)

        h = if item.is_a?(Hash)
              item.transform_keys(&:to_s)
            else
              (item.respond_to?(:to_h) ? item.to_h.transform_keys(&:to_s) : nil)
            end
        return item.to_s unless h

        case h['type']
        when 'text' then h['text'].to_s
        when nil
          h.key?('text') ? h['text'].to_s : JSON.generate(h)
        else
          "[non-text content omitted: type=#{h['type']}]"
        end
      end

      # --- client wiring ---

      def build_client(config)
        servers = config.fetch('servers')
        configs = servers.map { |name, cfg| build_server_config(name.to_s, cfg) }
        ::MCPClient.create_client(mcp_server_configs: configs)
      end

      def build_server_config(name, cfg)
        cfg ||= {}
        transport = (cfg['transport'] || detect_transport(cfg)).to_s

        case transport
        when 'stdio'
          base_command = cfg.fetch('command') do
            raise ConfigError, "stdio server '#{name}' missing 'command'"
          end
          # Upstream `stdio_config` accepts `command:` as either a String
          # (shell-parsed) or an Array (argv-style). We normalize to Array
          # whenever `args:` is supplied in the YAML — safer than shell
          # escaping the concatenation ourselves.
          command = cfg['args'] ? [base_command, *Array(cfg['args'])] : base_command
          kwargs = { command: command, name: name }
          kwargs[:env] = cfg['env'] if cfg['env']
          ::MCPClient.stdio_config(**kwargs)
        when 'sse'
          ::MCPClient.sse_config(
            base_url: cfg.fetch('url') { raise ConfigError, "sse server '#{name}' missing 'url'" },
            headers: cfg['headers'] || {},
            name: name
          )
        when 'http', 'streamable_http'
          ::MCPClient.streamable_http_config(
            base_url: cfg.fetch('url') { raise ConfigError, "http server '#{name}' missing 'url'" },
            headers: cfg['headers'] || {},
            name: name
          )
        else
          raise ConfigError, "unknown MCP transport for server '#{name}': #{transport.inspect}"
        end
      end

      def detect_transport(cfg)
        return 'stdio' if cfg['command']

        url = cfg['url'].to_s
        return 'sse' if url.include?('sse')

        'streamable_http'
      end
    end

    class << self
      # Load servers from a YAML config file. The file must contain a
      # top-level `servers:` key; each child is a server definition.
      def load(config_path)
        raw = File.read(config_path)
        expanded = expand_env(raw)
        config = YAML.safe_load(expanded, aliases: true, permitted_classes: [])
        unless config.is_a?(Hash) && config['servers'].is_a?(Hash) && config['servers'].any?
          raise ConfigError, "MCP config must declare at least one server under 'servers:'"
        end

        setup(config)
      end

      # Register the MCP protocol handler from an already-parsed config hash.
      # Useful from tests or programmatic setups. Pass `client:` to inject
      # a pre-built client instance (skips the upstream gem wiring).
      def setup(config, client: nil)
        shutdown if @adapter
        @adapter = Adapter.new(config, client: client)
        Kernai::Protocol.register(:mcp, documentation: MCP_DOCUMENTATION) do |block, ctx|
          @adapter.handle(block, ctx)
        end
        register_shutdown
        @adapter
      end

      def shutdown
        @adapter&.shutdown
        Kernai::Protocol.unregister(:mcp)
        @adapter = nil
      end

      attr_reader :adapter

      private

      def register_shutdown
        return if @shutdown_registered

        at_exit { shutdown }
        @shutdown_registered = true
      end

      # Substitute ${VAR} references with ENV values so config files can
      # carry auth tokens through environment variables without embedding
      # secrets.
      def expand_env(text)
        text.gsub(/\$\{([A-Z0-9_]+)\}/) { |_m| ENV[Regexp.last_match(1)].to_s }
      end
    end
  end
end
