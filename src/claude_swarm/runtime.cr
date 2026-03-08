require "json"

module ClaudeSwarm
  class ToolUseEvent
    include JSON::Serializable

    property name : String
    property input : Hash(String, JSON::Any)

    def initialize(@name : String, @input : Hash(String, JSON::Any) = Hash(String, JSON::Any).new)
    end
  end

  class RuntimeOptions
    property model : String
    property cwd : String
    property permission_mode : String
    property max_turns : Int32
    property max_budget_usd : Float64?
    property allowed_tools : Array(String)

    def initialize(
      @model : String,
      @cwd : String,
      @permission_mode : String = "default",
      @max_turns : Int32 = 3,
      @max_budget_usd : Float64? = nil,
      @allowed_tools : Array(String) = [] of String,
    )
    end
  end

  class RuntimeResult
    property text : String
    property total_cost_usd : Float64
    property tool_uses : Array(ToolUseEvent)

    def initialize(
      @text : String,
      @total_cost_usd : Float64 = 0.0,
      @tool_uses : Array(ToolUseEvent) = [] of ToolUseEvent,
    )
    end
  end

  class RuntimeError < Exception
  end

  abstract class AgentRuntime
    abstract def run(prompt : String, options : RuntimeOptions) : RuntimeResult
  end

  class SubprocessAgentRuntime < AgentRuntime
    DEFAULT_AGENT_COMMAND = "claude"

    getter command : String?
    getter claude_bin : String

    def initialize(
      @command : String? = ENV["CLAUDE_SWARM_AGENT_CMD"]?,
      @claude_bin : String = ENV["CLAUDE_BIN"]? || DEFAULT_AGENT_COMMAND,
    )
    end

    def run(prompt : String, options : RuntimeOptions) : RuntimeResult
      if command = @command
        run_custom_command(prompt, options, command)
      else
        run_claude_stream_json(prompt, options)
      end
    rescue error : File::NotFoundError
      raise RuntimeError.new(
        "Agent command not found. Set CLAUDE_SWARM_AGENT_CMD or ensure '#{@claude_bin}' is installed."
      )
    end

    private def run_custom_command(prompt : String, options : RuntimeOptions, command : String) : RuntimeResult
      output = IO::Memory.new
      error_output = IO::Memory.new
      process = Process.new(
        "/bin/sh",
        ["-lc", command],
        input: Process::Redirect::Pipe,
        output: output,
        error: error_output,
        chdir: options.cwd,
        env: build_swarm_env(options)
      )

      process.input.puts(prompt)
      process.input.close
      status = process.wait

      unless status.success?
        details = error_output.to_s.strip
        details = output.to_s.strip if details.empty?
        details = "command failed: #{command}" if details.empty?
        raise RuntimeError.new(details)
      end

      parse_swarm_protocol(output.to_s)
    end

    private def run_claude_stream_json(prompt : String, options : RuntimeOptions) : RuntimeResult
      output = IO::Memory.new
      error_output = IO::Memory.new
      process = Process.new(
        @claude_bin,
        build_claude_args(prompt, options),
        input: Process::Redirect::Close,
        output: output,
        error: error_output,
        chdir: options.cwd,
        env: ENV.to_h
      )

      status = process.wait
      unless status.success?
        details = error_output.to_s.strip
        details = output.to_s.strip if details.empty?
        details = "command failed: #{@claude_bin}" if details.empty?
        raise RuntimeError.new(details)
      end

      parse_claude_stream_json(output.to_s)
    end

    private def build_claude_args(prompt : String, options : RuntimeOptions) : Array(String)
      args = ["--print", "--output-format", "stream-json"]
      args += ["--model", options.model] unless options.model.empty?
      args += ["--permission-mode", options.permission_mode] unless options.permission_mode.empty?
      if max_budget = options.max_budget_usd
        args += ["--max-budget-usd", max_budget.to_s]
      end
      unless options.allowed_tools.empty?
        args += ["--allowed-tools", options.allowed_tools.join(",")]
      end
      args << prompt
      args
    end

    private def build_swarm_env(options : RuntimeOptions) : Hash(String, String)
      env = ENV.to_h
      env["CLAUDE_SWARM_MODEL"] = options.model
      env["CLAUDE_SWARM_PERMISSION_MODE"] = options.permission_mode
      env["CLAUDE_SWARM_MAX_TURNS"] = options.max_turns.to_s
      env["CLAUDE_SWARM_ALLOWED_TOOLS"] = options.allowed_tools.join(",")
      if max_budget = options.max_budget_usd
        env["CLAUDE_SWARM_MAX_BUDGET_USD"] = max_budget.to_s
      end
      env
    end

    private def parse_swarm_protocol(raw_output : String) : RuntimeResult
      text_lines = [] of String
      tool_uses = [] of ToolUseEvent
      total_cost = 0.0

      raw_output.each_line do |line|
        stripped = line.rstrip
        next if stripped.empty?

        if stripped.starts_with?("SWARM_TOOL\t")
          parts = stripped.split('\t', 3)
          name = parts[1]? || "unknown"
          input = parse_json_hash(parts[2]?)
          tool_uses << ToolUseEvent.new(name, input)
        elsif stripped.starts_with?("SWARM_COST\t")
          cost_str = stripped.split('\t', 2)[1]? || "0"
          total_cost = cost_str.to_f64? || total_cost
        elsif stripped.starts_with?("SWARM_TEXT\t")
          text = stripped.split('\t', 2)[1]? || ""
          text_lines << text
        else
          text_lines << stripped
        end
      end

      RuntimeResult.new(
        text: text_lines.join('\n'),
        total_cost_usd: total_cost,
        tool_uses: tool_uses
      )
    end

    private def parse_claude_stream_json(raw_output : String) : RuntimeResult
      text_chunks = [] of String
      tool_uses = [] of ToolUseEvent
      total_cost = 0.0

      raw_output.each_line do |line|
        stripped = line.strip
        next if stripped.empty?

        begin
          payload = JSON.parse(stripped)
        rescue JSON::ParseException
          text_chunks << stripped
          next
        end

        extract_text_chunks(payload).each { |chunk| text_chunks << chunk }
        extract_tool_uses(payload).each { |tool| tool_uses << tool }
        if cost = extract_cost(payload)
          total_cost = cost
        end
      end

      RuntimeResult.new(
        text: text_chunks.join('\n'),
        total_cost_usd: total_cost,
        tool_uses: tool_uses
      )
    end

    private def extract_text_chunks(payload : JSON::Any) : Array(String)
      chunks = [] of String
      flatten_json(payload).each do |node|
        next unless hash = node.as_h?
        next unless text = hash["text"]?.try(&.as_s?)
        node_type = hash["type"]?.try(&.as_s?) || ""
        if {"text", "text_delta", "text_block"}.includes?(node_type)
          chunks << text
        end
      end
      chunks
    end

    private def extract_tool_uses(payload : JSON::Any) : Array(ToolUseEvent)
      events = [] of ToolUseEvent
      flatten_json(payload).each do |node|
        next unless hash = node.as_h?
        node_type = hash["type"]?.try(&.as_s?) || ""
        next unless node_type.includes?("tool")
        next unless name = hash["name"]?.try(&.as_s?)
        next unless input = hash["input"]?.try(&.as_h?)

        events << ToolUseEvent.new(name, input)
      end
      events
    end

    private def extract_cost(payload : JSON::Any) : Float64?
      cost = nil
      flatten_json(payload).each do |node|
        next unless hash = node.as_h?
        if value = hash["total_cost_usd"]?
          cost = any_to_f64(value)
        elsif value = hash["cost_usd"]?
          cost = any_to_f64(value)
        end
      end
      cost
    end

    private def flatten_json(payload : JSON::Any) : Array(JSON::Any)
      nodes = [] of JSON::Any
      stack = [payload]

      until stack.empty?
        node = stack.pop
        nodes << node

        if hash = node.as_h?
          hash.each_value { |value| stack << value }
        elsif array = node.as_a?
          array.each { |value| stack << value }
        end
      end

      nodes
    end

    private def any_to_f64(value : JSON::Any) : Float64?
      raw = value.raw
      return raw.to_f64 if raw.is_a?(Float64)
      return raw.to_f64 if raw.is_a?(Int64)
      return raw.to_f64 if raw.is_a?(Int32)
      return raw.to_f64 if raw.is_a?(Float32)

      nil
    end

    private def parse_json_hash(raw_json : String?) : Hash(String, JSON::Any)
      return Hash(String, JSON::Any).new unless raw_json

      JSON.parse(raw_json).as_h
    rescue JSON::ParseException
      Hash(String, JSON::Any).new
    end
  end
end
