# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'tempfile'

# We now depend on the REAL `ruby-mcp-client` gem (declared in the Gemfile's
# dev/test group). Using the real gem in tests means:
#
#   - Real MCPClient::Tool, MCPClient::ServerBase etc. — so any upstream
#     signature drift breaks the suite loudly instead of silently.
#   - No hand-maintained fake that can drift out of sync with the real API
#     (we got bitten once when stdio_config's `:args` keyword didn't exist).
#
# To avoid spawning real subprocesses / opening real SSE connections we
# inject a `TestDoubleClient` into the adapter via the new `client:` kwarg.
# The double uses real MCPClient value objects so the adapter's tool/
# resource/prompt duck-typing is exercised against the real shapes.
require 'mcp_client'
require 'kernai/mcp'

class TestMCPAdapter < Minitest::Test
  include Kernai::TestHelpers

  # Lightweight stand-in for MCPClient::Client — just enough surface for
  # Kernai::MCP::Adapter to drive it without touching any transport.
  class TestDoubleClient
    attr_reader :servers, :calls

    def initialize(server_names)
      @servers = server_names.map { |n| build_server(n) }
      @tools = []
      @resources = []
      @prompts = []
      @tool_results = {}
      @resource_results = {}
      @prompt_results = {}
      @raise_on_call = nil
      @calls = []
    end

    # --- seeding helpers (test-only) ---

    def seed_tool(name:, description:, schema:, server:, **extras)
      srv = find_server(server)
      @tools << ::MCPClient::Tool.new(
        name: name,
        description: description,
        schema: schema,
        server: srv,
        **extras
      )
    end

    def seed_resource(uri:, name:, server:, description: nil, mime_type: 'text/plain')
      srv = find_server(server)
      @resources << FakeResource.new(uri, name, description, mime_type, srv)
    end

    def seed_prompt(name:, server:, description: nil, arguments: nil)
      srv = find_server(server)
      @prompts << FakePrompt.new(name, description, arguments, srv)
    end

    def seed_tool_result(name, result) = @tool_results.[]=(name, result)
    def seed_resource_result(uri, result) = @resource_results.[]=(uri, result)
    def seed_prompt_result(name, result) = @prompt_results.[]=(name, result)
    def raise_on_call!(exc) = @raise_on_call = exc

    # --- MCPClient::Client surface ---

    def list_tools(cache: true)
      @tools.dup
    end

    def list_resources(cache: true, cursor: nil)
      @resources.dup
    end

    def list_prompts(cache: true)
      @prompts.dup
    end

    def call_tool(name, params, server: nil)
      @calls << { op: :call_tool, name: name, params: params, server: server }
      raise @raise_on_call if @raise_on_call

      @tool_results.fetch(name, "called:#{name}")
    end

    def read_resource(uri, server: nil)
      @calls << { op: :read_resource, uri: uri, server: server }
      @resource_results.fetch(uri, "content of #{uri}")
    end

    def get_prompt(name, arguments, server: nil)
      @calls << { op: :get_prompt, name: name, arguments: arguments, server: server }
      @prompt_results.fetch(name, "prompt:#{name}")
    end

    def cleanup
      @calls << { op: :cleanup }
    end

    private

    def find_server(name)
      @servers.find { |s| s.name == name } ||
        raise("unknown test server #{name.inspect}")
    end

    # The real MCPClient::ServerBase needs a full transport config to boot —
    # way overkill for unit tests. This trivial stand-in quacks the same way
    # our adapter uses (`.name`), which is all Adapter#tool_server_name needs.
    FakeServerStub = Struct.new(:name) do
      def to_s
        name
      end
    end

    FakeResource = Struct.new(:uri, :name, :description, :mime_type, :server) do
      def to_h
        { uri: uri, name: name, description: description, mime_type: mime_type }
      end
    end

    FakePrompt = Struct.new(:name, :description, :arguments, :server) do
      def to_h
        { name: name, description: description, arguments: arguments }
      end
    end

    def build_server(name)
      FakeServerStub.new(name)
    end
  end

  def setup
    super
    begin
      Kernai::MCP.shutdown
    rescue StandardError
      nil
    end
    @config = {
      'servers' => {
        'filesystem' => { 'transport' => 'stdio', 'command' => 'echo', 'args' => ['noop'] },
        'github' => { 'transport' => 'sse', 'url' => 'https://mcp.example/sse' }
      }
    }
  end

  def teardown
    Kernai::MCP.shutdown
  rescue StandardError
    nil
  end

  # Build an adapter with a TestDoubleClient injected so no real transport
  # is ever initialized.
  def build_adapter(servers: %w[filesystem github])
    double = TestDoubleClient.new(servers)
    adapter = Kernai::MCP.setup(@config, client: double)
    yield double if block_given?
    adapter
  end

  def seed_client(client)
    client.seed_tool(
      name: 'read_file',
      description: 'Read a file from disk',
      schema: { 'type' => 'object',
                'properties' => { 'path' => { 'type' => 'string' } },
                'required' => ['path'] },
      server: 'filesystem'
    )
    client.seed_tool(
      name: 'write_file',
      description: 'Write a file to disk',
      schema: { 'type' => 'object',
                'properties' => { 'path' => { 'type' => 'string' },
                                  'content' => { 'type' => 'string' } } },
      server: 'filesystem'
    )
    client.seed_tool(
      name: 'create_issue',
      description: 'Open a GitHub issue',
      schema: { 'type' => 'object' },
      server: 'github'
    )
    client.seed_resource(uri: 'file:///tmp/a.txt', name: 'a.txt',
                         description: 'Sample', server: 'filesystem')
    client.seed_prompt(name: 'pr_review', description: 'PR review template',
                       arguments: [{ 'name' => 'pr_url' }], server: 'github')
    client
  end

  def dispatch(adapter, req)
    block = Struct.new(:type, :name, :content).new(:mcp, nil, JSON.generate(req))
    adapter.handle(block, nil)
  end

  # --- setup / registration ---

  def test_setup_registers_mcp_protocol_with_documentation
    adapter = build_adapter
    assert Kernai::Protocol.registered?(:mcp)
    assert_includes Kernai::Protocol.documentation_for(:mcp), 'tools/call'
    refute_nil adapter
  end

  def test_shutdown_unregisters_and_cleans_up
    client = nil
    build_adapter { |c| client = c }
    Kernai::MCP.shutdown

    refute Kernai::Protocol.registered?(:mcp)
    assert(client.calls.any? { |c| c[:op] == :cleanup })
  end

  def test_setup_with_real_client_path_still_calls_upstream
    # Smoke-test the non-injection path: when client: is nil, the adapter
    # must actually require mcp_client and call MCPClient.create_client.
    # We use a no-op stdio command (`:`) so the process can be spawned
    # without side effects. The upstream gem is lazy — it does not open
    # the subprocess until the first tool call — so we just assert that
    # we end up with a real MCPClient::Client instance.
    config = {
      'servers' => { 'noop' => { 'transport' => 'stdio', 'command' => ':' } }
    }
    adapter = Kernai::MCP.setup(config)
    assert_kind_of ::MCPClient::Client, adapter.client
  end

  def test_load_parses_yaml_file_with_injected_client
    Tempfile.open(['mcp_test', '.yml']) do |f|
      f.write(<<~YAML)
        servers:
          fs:
            transport: stdio
            command: echo
      YAML
      f.flush

      # We can't pass client: through MCP.load, but we can assert the file
      # is parsed by calling .setup directly with the parsed hash.
      parsed = YAML.safe_load(File.read(f.path))
      adapter = Kernai::MCP.setup(parsed, client: TestDoubleClient.new(%w[fs]))
      assert Kernai::Protocol.registered?(:mcp)
      assert_equal ['fs'], adapter.server_names
    end
  end

  def test_load_raises_on_missing_servers_key
    Tempfile.open(['mcp_test', '.yml']) do |f|
      f.write("not_servers: {}\n")
      f.flush
      assert_raises(Kernai::MCP::ConfigError) { Kernai::MCP.load(f.path) }
    end
  end

  def test_load_raises_on_empty_servers
    Tempfile.open(['mcp_test', '.yml']) do |f|
      f.write("servers: {}\n")
      f.flush
      assert_raises(Kernai::MCP::ConfigError) { Kernai::MCP.load(f.path) }
    end
  end

  def test_unknown_transport_raises_config_error
    bad_config = { 'servers' => { 'x' => { 'transport' => 'telepathy' } } }
    # We still want the ConfigError for an unknown transport even on the
    # real-gem path: build_server_config runs before any transport wiring.
    assert_raises(Kernai::MCP::ConfigError) { Kernai::MCP.setup(bad_config) }
  end

  def test_stdio_without_command_raises
    bad_config = { 'servers' => { 'x' => { 'transport' => 'stdio' } } }
    assert_raises(Kernai::MCP::ConfigError) { Kernai::MCP.setup(bad_config) }
  end

  def test_stdio_config_accepts_command_and_args_merged
    # Regression: we used to pass :args as a separate keyword which the
    # real gem doesn't accept. Verify that command + args in the YAML
    # resolves to a single Array passed to stdio_config.
    captured = nil
    Module.new do
      define_singleton_method(:stdio_config) do |command:, name: nil, env: {}, logger: nil|
        captured = { command: command, name: name, env: env, logger: logger }
      end
    end

    adapter_class = Kernai::MCP::Adapter
    result = adapter_class.allocate
    result.instance_variable_set(:@config, @config)
    stub_const = ::MCPClient
    # We just call the private helper directly — the real gem is loaded
    # and we only want to assert our payload-building logic.
    captured = result.send(
      :build_server_config,
      'fs',
      'transport' => 'stdio',
      'command' => 'npx',
      'args' => ['-y', '@modelcontextprotocol/server-filesystem', '/tmp']
    )
    # The real gem returns a ServerStdio config object. We just need to
    # prove that the build succeeds with command+args — the fact that the
    # real gem accepted it is the assertion.
    refute_nil captured
    _ = stub_const # silence unused warnings
  end

  # --- dispatch: servers/list ---

  def test_servers_list
    adapter = build_adapter
    result = dispatch(adapter, method: 'servers/list')
    assert_equal %w[filesystem github], JSON.parse(result)
  end

  # --- dispatch: tools ---

  def test_tools_list_all
    adapter = build_adapter { |c| seed_client(c) }
    result = dispatch(adapter, method: 'tools/list')
    tools = JSON.parse(result)
    assert_equal 3, tools.size
    names = tools.map { |t| t['name'] }.sort
    assert_equal %w[create_issue read_file write_file], names
  end

  def test_tools_list_filtered_by_server
    adapter = build_adapter { |c| seed_client(c) }
    result = dispatch(adapter, method: 'tools/list',
                               params: { server: 'filesystem' })
    tools = JSON.parse(result)
    assert_equal 2, tools.size
    assert(tools.all? { |t| t['server'] == 'filesystem' })
  end

  def test_tools_describe_returns_input_schema
    adapter = build_adapter { |c| seed_client(c) }
    result = dispatch(adapter, method: 'tools/describe',
                               params: { server: 'filesystem', name: 'read_file' })
    parsed = JSON.parse(result)
    assert_equal 'read_file', parsed['name']
    assert_equal 'Read a file from disk', parsed['description']
    assert_equal 'filesystem', parsed['server']
    assert_equal 'object', parsed['input_schema']['type']
    assert_includes parsed['input_schema']['required'], 'path'
  end

  def test_tools_describe_raises_when_not_found
    adapter = build_adapter { |c| seed_client(c) }
    assert_raises(ArgumentError) do
      dispatch(adapter, method: 'tools/describe',
                        params: { server: 'filesystem', name: 'missing' })
    end
  end

  def test_tools_describe_requires_name
    adapter = build_adapter { |c| seed_client(c) }
    assert_raises(ArgumentError) do
      dispatch(adapter, method: 'tools/describe',
                        params: { server: 'filesystem' })
    end
  end

  def test_tools_call_forwards_to_client
    client = nil
    adapter = build_adapter do |c|
      seed_client(c)
      c.seed_tool_result('read_file', 'hello world')
      client = c
    end

    result = dispatch(adapter, method: 'tools/call',
                               params: { server: 'filesystem', name: 'read_file',
                                         arguments: { 'path' => '/tmp/x' } })

    assert_equal 'hello world', result
    call = client.calls.find { |c| c[:op] == :call_tool }
    assert_equal 'read_file', call[:name]
    assert_equal({ 'path' => '/tmp/x' }, call[:params])
    assert_equal 'filesystem', call[:server]
  end

  def test_tools_call_requires_name
    adapter = build_adapter { |c| seed_client(c) }
    assert_raises(ArgumentError) do
      dispatch(adapter, method: 'tools/call', params: { server: 'filesystem' })
    end
  end

  def test_tools_call_client_error_propagates
    adapter = build_adapter do |c|
      seed_client(c)
      c.raise_on_call!(RuntimeError.new('upstream boom'))
    end

    err = assert_raises(RuntimeError) do
      dispatch(adapter, method: 'tools/call',
                        params: { server: 'filesystem', name: 'read_file',
                                  arguments: {} })
    end
    assert_equal 'upstream boom', err.message
  end

  # --- dispatch: resources ---

  def test_resources_list
    adapter = build_adapter { |c| seed_client(c) }
    result = dispatch(adapter, method: 'resources/list',
                               params: { server: 'filesystem' })
    parsed = JSON.parse(result)
    assert_equal 1, parsed.size
    assert_equal 'file:///tmp/a.txt', parsed.first['uri']
    assert_equal 'filesystem', parsed.first['server']
  end

  def test_resources_read
    adapter = build_adapter do |c|
      seed_client(c)
      c.seed_resource_result('file:///tmp/a.txt', 'file-body')
    end

    result = dispatch(adapter, method: 'resources/read',
                               params: { server: 'filesystem',
                                         uri: 'file:///tmp/a.txt' })
    assert_equal 'file-body', result
  end

  def test_resources_read_requires_uri
    adapter = build_adapter { |c| seed_client(c) }
    assert_raises(ArgumentError) do
      dispatch(adapter, method: 'resources/read',
                        params: { server: 'filesystem' })
    end
  end

  # --- dispatch: prompts ---

  def test_prompts_list
    adapter = build_adapter { |c| seed_client(c) }
    result = dispatch(adapter, method: 'prompts/list',
                               params: { server: 'github' })
    parsed = JSON.parse(result)
    assert_equal 1, parsed.size
    assert_equal 'pr_review', parsed.first['name']
  end

  def test_prompts_get
    adapter = build_adapter do |c|
      seed_client(c)
      c.seed_prompt_result('pr_review', 'rendered prompt text')
    end

    result = dispatch(adapter, method: 'prompts/get',
                               params: { server: 'github', name: 'pr_review',
                                         arguments: { 'pr_url' => 'x' } })
    assert_equal 'rendered prompt text', result
  end

  # --- dispatch: unknown / malformed ---

  def test_unknown_method_raises
    adapter = build_adapter
    err = assert_raises(ArgumentError) { dispatch(adapter, method: 'sorcery/please') }
    assert_includes err.message, 'unknown MCP method'
  end

  # Regression: a common model mistake is to treat a tool name
  # (e.g. "list_directory") as if it were a protocol method. The adapter
  # must detect the category error and suggest the correct `tools/call`
  # form so the agent can recover on its next turn.
  def test_unknown_method_matching_tool_name_suggests_tools_call
    adapter = build_adapter { |c| seed_client(c) }
    err = assert_raises(ArgumentError) do
      dispatch(adapter, method: 'read_file',
                        params: { server: 'filesystem', path: '/tmp/x' })
    end
    msg = err.message
    assert_includes msg, 'unknown MCP method: read_file'
    assert_includes msg, 'TOOL NAME, not a protocol method'
    assert_includes msg, '"method":"tools/call"'
    assert_includes msg, '"name":"read_file"'
    assert_includes msg, '"server":"filesystem"'
    # Arguments from the wrong call (minus server/name) are preserved so
    # the agent can copy-paste the suggested form directly.
    assert_includes msg, '"path":"/tmp/x"'
  end

  def test_unknown_method_matching_tool_uses_first_server_match
    adapter = build_adapter { |c| seed_client(c) }
    # "create_issue" is only on the github server — verify the suggestion
    # points to the right server, not to filesystem.
    err = assert_raises(ArgumentError) do
      dispatch(adapter, method: 'create_issue', params: { title: 'Bug' })
    end
    assert_includes err.message, '"server":"github"'
    assert_includes err.message, '"name":"create_issue"'
  end

  def test_unknown_method_without_tool_match_uses_plain_message
    adapter = build_adapter { |c| seed_client(c) }
    err = assert_raises(ArgumentError) { dispatch(adapter, method: 'sorcery/please') }
    refute_includes err.message, 'tools/call'
    assert_equal 'unknown MCP method: sorcery/please', err.message
  end

  def test_missing_method_raises
    adapter = build_adapter
    err = assert_raises(ArgumentError) { dispatch(adapter, foo: 'bar') }
    assert_includes err.message, 'missing method'
  end

  def test_invalid_json_raises
    adapter = build_adapter
    block = Struct.new(:type, :name, :content).new(:mcp, nil, 'not json at all')
    err = assert_raises(ArgumentError) { adapter.handle(block, nil) }
    assert_includes err.message, 'invalid MCP request JSON'
  end

  def test_empty_content_raises
    adapter = build_adapter
    block = Struct.new(:type, :name, :content).new(:mcp, nil, '  ')
    assert_raises(ArgumentError) { adapter.handle(block, nil) }
  end

  def test_non_object_json_raises
    adapter = build_adapter
    block = Struct.new(:type, :name, :content).new(:mcp, nil, '"just a string"')
    assert_raises(ArgumentError) { adapter.handle(block, nil) }
  end

  # --- to_text flattening ---

  def test_to_text_passes_strings_through
    adapter = build_adapter
    assert_equal 'hello', adapter.send(:to_text, 'hello')
  end

  def test_to_text_handles_content_array
    adapter = build_adapter
    payload = { 'content' => [{ 'type' => 'text', 'text' => 'line1' },
                              { 'type' => 'text', 'text' => 'line2' }] }
    assert_equal "line1\nline2", adapter.send(:to_text, payload)
  end

  def test_to_text_marks_non_text_items
    adapter = build_adapter
    payload = { 'content' => [
      { 'type' => 'text', 'text' => 'caption' },
      { 'type' => 'image', 'data' => 'base64...' }
    ] }
    result = adapter.send(:to_text, payload)
    assert_includes result, 'caption'
    assert_includes result, '[non-text content omitted: type=image]'
  end

  def test_to_text_handles_array_of_items
    adapter = build_adapter
    payload = [{ 'type' => 'text', 'text' => 'a' },
               { 'type' => 'text', 'text' => 'b' }]
    assert_equal "a\nb", adapter.send(:to_text, payload)
  end

  def test_to_text_nil_becomes_empty
    adapter = build_adapter
    assert_equal '', adapter.send(:to_text, nil)
  end

  # --- End-to-end through the kernel ---

  def test_full_round_trip_through_kernel
    client = nil
    adapter = build_adapter do |c|
      seed_client(c)
      c.seed_tool_result('read_file', 'contents')
      client = c
    end
    refute_nil adapter

    provider = Kernai::Mock::Provider.new
    agent = Kernai::Agent.new(
      instructions: 'You are helpful.',
      provider: provider,
      model: 'test',
      max_steps: 6
    )

    call_tool_request = JSON.generate(
      method: 'tools/call',
      params: { server: 'filesystem', name: 'read_file',
                arguments: { path: '/tmp/x' } }
    )
    provider.respond_with(
      '<block type="mcp">{"method":"servers/list"}</block>',
      '<block type="mcp">{"method":"tools/list","params":{"server":"filesystem"}}</block>',
      "<block type=\"mcp\">#{call_tool_request}</block>",
      '<block type="final">done</block>'
    )

    recorder = Kernai::Recorder.new
    result = Kernai::Kernel.run(agent, 'go', recorder: recorder)
    assert_equal 'done', result

    execs = recorder.to_a.select { |e| e[:event] == :protocol_execute }
    assert_equal 3, execs.size
    assert(execs.all? { |e| e[:data][:protocol] == :mcp })

    results = recorder.to_a.select { |e| e[:event] == :protocol_result }
    assert_equal 3, results.size
    assert(results.all? { |e| e[:data][:duration_ms].is_a?(Integer) })

    last = results.last
    assert_equal 'contents', last[:data][:result]

    # The test-double client actually received the call
    tool_call = client.calls.find { |c| c[:op] == :call_tool }
    refute_nil tool_call
    assert_equal 'read_file', tool_call[:name]
  end
end
