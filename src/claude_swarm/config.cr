require "yaml"

module ClaudeSwarm
  class AgentConfig
    property name : String
    property description : String
    property model : String
    property tools : Array(String)
    property prompt : String

    def initialize(
      @name : String,
      @description : String,
      @model : String = "haiku",
      @tools : Array(String) = SwarmConfig.default_tools,
      @prompt : String = "",
    )
    end
  end

  class ConnectionConfig
    property from_agents : Array(String)
    property to_agent : String

    def initialize(@from_agents : Array(String), @to_agent : String)
    end
  end

  class SwarmConfig
    property name : String
    property max_concurrent : Int32
    property budget_usd : Float64
    property model : String
    property agents : Hash(String, AgentConfig)
    property connections : Array(ConnectionConfig)

    def self.default_tools : Array(String)
      ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]
    end

    def initialize(
      @name : String = "default",
      @max_concurrent : Int32 = 4,
      @budget_usd : Float64 = 5.0,
      @model : String = "opus",
      @agents : Hash(String, AgentConfig) = Hash(String, AgentConfig).new,
      @connections : Array(ConnectionConfig) = [] of ConnectionConfig,
    )
    end

    def self.from_file(path : String) : SwarmConfig
      raise "Config file not found: #{path}" unless File.exists?(path)

      from_yaml(File.read(path))
    end

    def self.from_yaml(content : String) : SwarmConfig
      from_any(YAML.parse(content))
    end

    def self.from_any(root : YAML::Any) : SwarmConfig
      swarm_data = root["swarm"]?
      config = new(
        name: swarm_data.try(&.["name"]?.try(&.as_s)) || "default",
        max_concurrent: swarm_data.try(&.["max_concurrent"]?.try(&.as_i)) || 4,
        budget_usd: swarm_data.try(&.["budget_usd"]?.try(&.as_f)) || 5.0,
        model: swarm_data.try(&.["model"]?.try(&.as_s)) || "opus"
      )

      root["agents"]?.try(&.as_h).try do |agents|
        agents.each do |name_any, agent_data_any|
          name = name_any.to_s
          agent_data = agent_data_any
          config.agents[name] = AgentConfig.new(
            name: name,
            description: agent_data["description"]?.try(&.as_s) || "Agent: #{name}",
            model: agent_data["model"]?.try(&.as_s) || "haiku",
            tools: agent_data["tools"]?.try do |tools_any|
              tools_any.as_a.map(&.as_s)
            end || default_tools,
            prompt: agent_data["prompt"]?.try(&.as_s) || ""
          )
        end
      end

      root["connections"]?.try(&.as_a).try do |connections|
        connections.each do |conn_data|
          from_agents = conn_data["from"]?.try do |from_any|
            case from_any.raw
            when String
              [from_any.as_s]
            when Array
              from_any.as_a.map(&.as_s)
            else
              [] of String
            end
          end || [] of String

          config.connections << ConnectionConfig.new(
            from_agents: from_agents,
            to_agent: conn_data["to"]?.try(&.as_s) || ""
          )
        end
      end

      config
    end

    def get_agent_prompt(agent_type : String) : String
      agents[agent_type]?.try(&.prompt) || ""
    end

    def get_agent_tools(agent_type : String) : Array(String)
      agents[agent_type]?.try(&.tools) || self.class.default_tools
    end

    def get_agent_model(agent_type : String) : String
      agents[agent_type]?.try(&.model) || "haiku"
    end
  end

  def self.find_config(cwd : String) : SwarmConfig?
    [
      File.join(cwd, "swarm.yaml"),
      File.join(cwd, "swarm.yml"),
      File.join(cwd, ".claude", "swarm.yaml"),
      File.join(cwd, ".claude", "swarm.yml"),
    ].each do |path|
      return SwarmConfig.from_file(path) if File.exists?(path)
    end

    nil
  end
end
