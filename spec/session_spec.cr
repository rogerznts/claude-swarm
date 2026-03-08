require "./spec_helper"

describe ClaudeSwarm::SessionRecorder do
  it "records metadata and events" do
    with_tmpdir do |tmpdir|
      recorder = ClaudeSwarm::SessionRecorder.new("test-session-001", tmpdir)
      recorder.start("Test task", "/tmp/project")
      recorder.record_plan({"tasks" => JSON::Any.new([] of JSON::Any)})
      recorder.record_agent_started("agent-1", "t1", "Do thing")
      recorder.record_tool_use("agent-1", "t1", "Read", {"file_path" => JSON::Any.new("/tmp/test.py")})
      recorder.record_agent_completed("agent-1", "t1", 0.05, 5000)
      recorder.finish({"completed" => JSON::Any.new(1), "total_cost_usd" => JSON::Any.new(0.05)})

      session_dir = File.join(tmpdir, "test-session-001")
      File.exists?(File.join(session_dir, "metadata.json")).should be_true
      File.exists?(File.join(session_dir, "events.jsonl")).should be_true

      events = ClaudeSwarm.load_session_events("test-session-001", tmpdir)
      events.size.should eq(6)

      sessions = ClaudeSwarm.list_sessions(20, tmpdir)
      sessions.first["session_id"].as_s.should eq("test-session-001")
    end
  end
end
