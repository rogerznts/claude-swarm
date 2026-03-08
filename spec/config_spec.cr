require "./spec_helper"

describe ClaudeSwarm::SwarmConfig do
  it "loads config from yaml with defaults" do
    yaml = <<-YAML
    swarm:
      name: review
      max_concurrent: 2
      budget_usd: 3.0
    agents:
      security:
        description: Security reviewer
        model: opus
        tools: [Read, Grep]
        prompt: Analyze for vulnerabilities
    connections:
      - from: coder
        to: reviewer
    YAML

    config = ClaudeSwarm::SwarmConfig.from_yaml(yaml)
    config.name.should eq("review")
    config.max_concurrent.should eq(2)
    config.budget_usd.should eq(3.0)
    config.agents["security"].model.should eq("opus")
    config.connections.first.from_agents.should eq(["coder"])
  end

  it "falls back to default tools and prompts" do
    config = ClaudeSwarm::SwarmConfig.new
    config.get_agent_prompt("unknown").should eq("")
    config.get_agent_tools("unknown").should contain("Write")
  end
end
