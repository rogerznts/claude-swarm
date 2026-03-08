require "./spec_helper"

describe ClaudeSwarm::Decomposer do
  it "extracts a fenced json block" do
    text = <<-TEXT
    Here is the plan:

    ```json
    {"tasks": [{"id": "task-1", "description": "Do something"}]}
    ```
    TEXT

    result = ClaudeSwarm::Decomposer.extract_json_block(text)
    result.should_not be_nil
    result.not_nil!.should contain(%("task-1"))
  end

  it "parses valid decomposition" do
    text = <<-TEXT
    ```json
    {
      "tasks": [
        {
          "id": "task-1",
          "description": "Implement auth",
          "agent_type": "coder",
          "dependencies": [],
          "files_to_modify": ["src/auth.ts"],
          "tools": ["Read", "Write"],
          "prompt": "Implement authentication"
        }
      ]
    }
    ```
    TEXT

    tasks = ClaudeSwarm::Decomposer.parse_decomposition(text)
    tasks.size.should eq(1)
    tasks.first.id.should eq("task-1")
    tasks.first.agent_type.should eq("coder")
  end

  it "falls back to a single task when parsing fails" do
    tasks = ClaudeSwarm::Decomposer.parse_decomposition("not json")
    tasks.size.should eq(1)
    tasks.first.agent_type.should eq("coder")
  end
end
