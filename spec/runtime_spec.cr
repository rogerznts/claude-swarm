require "./spec_helper"

describe ClaudeSwarm::SubprocessAgentRuntime do
  it "parses the SWARM protocol from command output" do
    runtime = ClaudeSwarm::SubprocessAgentRuntime.new(
      "cat >/dev/null; printf 'SWARM_TEXT\\thello\\nSWARM_TOOL\\tRead\\t{\"file_path\":\"foo.txt\"}\\nSWARM_COST\\t0.12\\n'"
    )

    result = runtime.run("prompt", ClaudeSwarm::RuntimeOptions.new(model: "haiku", cwd: "/tmp"))

    result.text.should eq("hello")
    result.tool_uses.size.should eq(1)
    result.tool_uses.first.name.should eq("Read")
    result.tool_uses.first.input["file_path"].as_s.should eq("foo.txt")
    result.total_cost_usd.should eq(0.12)
  end

  it "adapts claude stream-json output into SWARM events" do
    with_tmpdir do |tmpdir|
      fake_claude = File.join(tmpdir, "fake-claude")
      File.write(
        fake_claude,
        <<-SH
        #!/bin/sh
        printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"src/app.cr"}},{"type":"text","text":"done"}]}}'
        printf '%s\n' '{"type":"result","total_cost_usd":0.42}'
        SH
      )
      File.chmod(fake_claude, 0o755)

      runtime = ClaudeSwarm::SubprocessAgentRuntime.new(nil, fake_claude)

      result = runtime.run("prompt", ClaudeSwarm::RuntimeOptions.new(model: "haiku", cwd: tmpdir))

      result.text.should eq("done")
      result.tool_uses.size.should eq(1)
      result.tool_uses.first.name.should eq("Read")
      result.tool_uses.first.input["file_path"].as_s.should eq("src/app.cr")
      result.total_cost_usd.should eq(0.42)
    end
  end
end
