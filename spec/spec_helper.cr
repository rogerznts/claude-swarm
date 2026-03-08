require "spec"
require "../src/claude_swarm"

def with_tmpdir(&)
  base = ENV["TMPDIR"]? || "/tmp"
  dir = File.join(base, "claude-swarm-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

class FakeRuntimeResponse
  getter result : ClaudeSwarm::RuntimeResult?
  getter error : String?
  getter delay_ms : Int32

  def initialize(@result : ClaudeSwarm::RuntimeResult? = nil, @error : String? = nil, @delay_ms : Int32 = 0)
  end
end

class FakeRuntime < ClaudeSwarm::AgentRuntime
  getter calls : Array(String)

  def initialize
    @calls = [] of String
    @responses = Hash(String, Array(FakeRuntimeResponse)).new do |hash, key|
      hash[key] = [] of FakeRuntimeResponse
    end
  end

  def push_result(
    prompt : String,
    text : String,
    total_cost_usd : Float64 = 0.0,
    tool_uses : Array(ClaudeSwarm::ToolUseEvent) = [] of ClaudeSwarm::ToolUseEvent,
    delay_ms : Int32 = 0,
  ) : Nil
    @responses[prompt] << FakeRuntimeResponse.new(
      result: ClaudeSwarm::RuntimeResult.new(text, total_cost_usd, tool_uses),
      delay_ms: delay_ms
    )
  end

  def push_error(prompt : String, error : String) : Nil
    @responses[prompt] << FakeRuntimeResponse.new(error: error)
  end

  def run(prompt : String, options : ClaudeSwarm::RuntimeOptions) : ClaudeSwarm::RuntimeResult
    @calls << "#{options.model}:#{prompt}"
    response = @responses[prompt].shift? || FakeRuntimeResponse.new(
      result: ClaudeSwarm::RuntimeResult.new(prompt)
    )

    if error = response.error
      raise ClaudeSwarm::RuntimeError.new(error)
    end

    sleep response.delay_ms.milliseconds if response.delay_ms > 0
    result = response.result.not_nil!
    result
  end
end
