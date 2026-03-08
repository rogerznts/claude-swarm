require "./spec_helper"

describe ClaudeSwarm::QualityGate do
  it "builds task summaries" do
    task = ClaudeSwarm::SwarmTask.new(
      id: "t1",
      description: "Create auth routes",
      agent_type: "coder",
      status: ClaudeSwarm::TaskStatus::Completed,
      files_to_modify: ["src/auth.ts"],
      result: "Created login and register endpoints",
      cost_usd: 0.05,
      duration_ms: 5000
    )
    result = ClaudeSwarm::SwarmResult.new(
      plan: ClaudeSwarm::SwarmPlan.new("Add auth", [task]),
      completed_tasks: [task],
      failed_tasks: [] of ClaudeSwarm::SwarmTask,
      conflicts: [] of ClaudeSwarm::FileConflict,
      total_cost_usd: 0.05,
      total_duration_ms: 5000,
      agents_used: 1
    )

    summary = ClaudeSwarm::QualityGate.build_task_summaries(result)
    summary.should contain("COMPLETED")
    summary.should contain("auth.ts")
  end

  it "parses a valid quality report" do
    json = %({"overall_score":8,"verdict":"pass","summary":"Good work","task_reviews":[{"task_id":"t1","score":9,"issues":[],"suggestions":["Add error handling"]}],"integration_issues":[],"missing_items":[]})
    report = ClaudeSwarm::QualityGate.parse_quality_report("```json\n#{json}\n```", 0.02)
    report.overall_score.should eq(8)
    report.task_reviews.size.should eq(1)
    report.review_cost_usd.should eq(0.02)
  end

  it "falls back when the payload is invalid" do
    report = ClaudeSwarm::QualityGate.parse_quality_report("not json", 0.01)
    report.verdict.should eq("pass")
    report.review_cost_usd.should eq(0.01)
  end
end
