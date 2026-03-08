require "./spec_helper"

private def make_plan(tasks : Array(ClaudeSwarm::SwarmTask))
  ClaudeSwarm::SwarmPlan.new(original_prompt: "test", tasks: tasks)
end

describe ClaudeSwarm::SwarmOrchestrator do
  it "returns ready tasks without dependencies" do
    tasks = [
      ClaudeSwarm::SwarmTask.new(id: "a", description: "A", agent_type: "coder"),
      ClaudeSwarm::SwarmTask.new(id: "b", description: "B", agent_type: "coder"),
    ]
    orchestrator = ClaudeSwarm::SwarmOrchestrator.new(plan: make_plan(tasks), cwd: "/tmp")
    orchestrator.ready_tasks.size.should eq(2)
  end

  it "detects file conflicts" do
    tasks = [
      ClaudeSwarm::SwarmTask.new(id: "a", description: "A", agent_type: "coder", files_to_modify: ["src/auth.ts"]),
      ClaudeSwarm::SwarmTask.new(id: "b", description: "B", agent_type: "coder", files_to_modify: ["src/auth.ts"]),
    ]

    orchestrator = ClaudeSwarm::SwarmOrchestrator.new(plan: make_plan(tasks), cwd: "/tmp")
    agent = ClaudeSwarm::SwarmAgent.new(id: "agent-a", name: "coder-a", task_id: "a", status: ClaudeSwarm::AgentStatus::Working)
    orchestrator.agents["agent-a"] = agent
    task = tasks.first
    task.assigned_agent = "agent-a"
    orchestrator.lock_files(task)

    conflict = orchestrator.check_file_conflict(tasks.last)
    conflict.should_not be_nil
    conflict.not_nil!.file_path.should eq("src/auth.ts")
  end

  it "retries a task and succeeds on the second attempt" do
    runtime = FakeRuntime.new
    runtime.push_error("retry prompt", "boom")
    runtime.push_result("retry prompt", "done", 0.05)

    task = ClaudeSwarm::SwarmTask.new(
      id: "a",
      description: "A",
      agent_type: "coder",
      prompt: "retry prompt",
      tools: ["Read"]
    )

    orchestrator = ClaudeSwarm::SwarmOrchestrator.new(
      plan: make_plan([task]),
      cwd: "/tmp",
      max_retries: 2,
      runtime: runtime
    )
    result = orchestrator.run

    result.completed_tasks.size.should eq(1)
    result.failed_tasks.should be_empty
    task.result.should_not be_nil
    task.result.not_nil!.should contain("done")
  end

  it "cancels pending work when budget is exceeded" do
    runtime = FakeRuntime.new
    runtime.push_result("task a", "done", 10.0)

    tasks = [
      ClaudeSwarm::SwarmTask.new(id: "a", description: "A", agent_type: "coder", prompt: "task a", tools: ["Read"]),
      ClaudeSwarm::SwarmTask.new(id: "b", description: "B", agent_type: "coder", dependencies: ["a"], prompt: "task b", tools: ["Read"]),
    ]

    orchestrator = ClaudeSwarm::SwarmOrchestrator.new(
      plan: make_plan(tasks),
      cwd: "/tmp",
      max_concurrent: 1,
      max_budget_usd: 5.0,
      runtime: runtime
    )
    result = orchestrator.run

    result.completed_tasks.map(&.id).should contain("a")
    tasks.last.status.should eq(ClaudeSwarm::TaskStatus::Cancelled)
  end

  it "unblocks file-conflicted tasks after the lock is released" do
    tasks = [
      ClaudeSwarm::SwarmTask.new(id: "a", description: "A", agent_type: "coder", files_to_modify: ["src/auth.ts"]),
      ClaudeSwarm::SwarmTask.new(
        id: "b",
        description: "B",
        agent_type: "coder",
        status: ClaudeSwarm::TaskStatus::Blocked,
        files_to_modify: ["src/auth.ts"]
      ),
    ]

    orchestrator = ClaudeSwarm::SwarmOrchestrator.new(plan: make_plan(tasks), cwd: "/tmp")
    agent = ClaudeSwarm::SwarmAgent.new(id: "agent-a", name: "coder-a", task_id: "a", status: ClaudeSwarm::AgentStatus::Working)
    orchestrator.agents["agent-a"] = agent
    tasks.first.assigned_agent = "agent-a"
    orchestrator.lock_files(tasks.first)

    orchestrator.refresh_blocked_tasks
    tasks.last.status.should eq(ClaudeSwarm::TaskStatus::Blocked)

    orchestrator.unlock_files(tasks.first)
    agent.status = ClaudeSwarm::AgentStatus::Completed
    orchestrator.refresh_blocked_tasks
    tasks.last.status.should eq(ClaudeSwarm::TaskStatus::Pending)
  end

  it "runs independent tasks in parallel" do
    runtime = FakeRuntime.new
    runtime.push_result("task a", "done a", delay_ms: 200)
    runtime.push_result("task b", "done b", delay_ms: 200)

    tasks = [
      ClaudeSwarm::SwarmTask.new(id: "a", description: "A", agent_type: "coder", prompt: "task a", tools: ["Read"]),
      ClaudeSwarm::SwarmTask.new(id: "b", description: "B", agent_type: "coder", prompt: "task b", tools: ["Read"]),
    ]

    orchestrator = ClaudeSwarm::SwarmOrchestrator.new(
      plan: make_plan(tasks),
      cwd: "/tmp",
      max_concurrent: 2,
      runtime: runtime
    )

    started = Time.instant
    result = orchestrator.run
    elapsed_ms = (Time.instant - started).total_milliseconds

    result.completed_tasks.size.should eq(2)
    elapsed_ms.should be < 350.0
  end
end
