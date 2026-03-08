require "./spec_helper"

describe ClaudeSwarm::SwarmTask do
  it "is ready when pending without dependencies" do
    task = ClaudeSwarm::SwarmTask.new(
      id: "task-1",
      description: "Test task",
      agent_type: "coder"
    )
    task.is_ready.should be_true
  end

  it "is not ready when dependencies exist" do
    task = ClaudeSwarm::SwarmTask.new(
      id: "task-2",
      description: "Test task",
      agent_type: "coder",
      dependencies: ["task-1"]
    )
    task.is_ready.should be_false
  end
end

describe ClaudeSwarm::SwarmPlan do
  it "groups independent tasks in parallel" do
    plan = ClaudeSwarm::SwarmPlan.new(
      original_prompt: "test",
      tasks: [
        ClaudeSwarm::SwarmTask.new(id: "a", description: "A", agent_type: "coder"),
        ClaudeSwarm::SwarmTask.new(id: "b", description: "B", agent_type: "coder"),
        ClaudeSwarm::SwarmTask.new(
          id: "c",
          description: "C",
          agent_type: "reviewer",
          dependencies: ["a", "b"]
        ),
      ]
    )

    plan.parallel_groups.should eq([["a", "b"], ["c"]])
  end
end
