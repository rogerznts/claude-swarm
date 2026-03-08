require "json"

module ClaudeSwarm
  enum TaskStatus
    Pending
    Blocked
    Running
    Completed
    Failed
    Cancelled

    def to_s(io : IO) : Nil
      io << case self
      in .pending?   then "pending"
      in .blocked?   then "blocked"
      in .running?   then "running"
      in .completed? then "completed"
      in .failed?    then "failed"
      in .cancelled? then "cancelled"
      end
    end
  end

  enum AgentStatus
    Idle
    Working
    Blocked
    Completed
    Failed

    def to_s(io : IO) : Nil
      io << case self
      in .idle?      then "idle"
      in .working?   then "working"
      in .blocked?   then "blocked"
      in .completed? then "completed"
      in .failed?    then "failed"
      end
    end
  end

  class SwarmTask
    include JSON::Serializable

    property id : String
    property description : String
    property agent_type : String
    property status : TaskStatus
    property dependencies : Array(String)
    property assigned_agent : String?
    property files_to_modify : Array(String)
    property result : String?
    property error : String?
    property cost_usd : Float64
    property duration_ms : Int32
    property tools : Array(String)
    property prompt : String

    def initialize(
      @id : String,
      @description : String,
      @agent_type : String,
      @status : TaskStatus = TaskStatus::Pending,
      @dependencies : Array(String) = [] of String,
      @assigned_agent : String? = nil,
      @files_to_modify : Array(String) = [] of String,
      @result : String? = nil,
      @error : String? = nil,
      @cost_usd : Float64 = 0.0,
      @duration_ms : Int32 = 0,
      @tools : Array(String) = [] of String,
      @prompt : String = "",
    )
    end

    def is_ready : Bool
      status.pending? && dependencies.empty?
    end

    def to_agent_definition_hash : Hash(String, JSON::Any)
      {
        "description" => JSON::Any.new(description),
        "prompt"      => JSON::Any.new(prompt),
        "model"       => JSON::Any.new("haiku"),
        "tools"       => JSON::Any.new(tools.map { |tool| JSON::Any.new(tool) }),
      }
    end
  end

  class SwarmAgent
    include JSON::Serializable

    property id : String
    property name : String
    property task_id : String
    property status : AgentStatus
    property cost_usd : Float64
    property turns : Int32
    property files_modified : Array(String)
    property current_tool : String?

    def initialize(
      @id : String,
      @name : String,
      @task_id : String,
      @status : AgentStatus = AgentStatus::Idle,
      @cost_usd : Float64 = 0.0,
      @turns : Int32 = 0,
      @files_modified : Array(String) = [] of String,
      @current_tool : String? = nil,
    )
    end
  end

  class FileConflict
    include JSON::Serializable

    property file_path : String
    property agent_ids : Array(String)
    property task_ids : Array(String)
    property resolved : Bool

    def initialize(
      @file_path : String,
      @agent_ids : Array(String),
      @task_ids : Array(String),
      @resolved : Bool = false,
    )
    end
  end

  class SwarmPlan
    include JSON::Serializable

    property original_prompt : String
    property tasks : Array(SwarmTask)
    property estimated_total_cost : Float64
    property model_used : String

    def initialize(
      @original_prompt : String,
      @tasks : Array(SwarmTask),
      @estimated_total_cost : Float64 = 0.0,
      @model_used : String = "opus",
    )
    end

    def task_count : Int32
      tasks.size
    end

    def parallel_groups : Array(Array(String))
      remaining = Hash(String, Set(String)).new
      tasks.each do |task|
        remaining[task.id] = task.dependencies.to_set
      end

      groups = [] of Array(String)

      until remaining.empty?
        ready = remaining.compact_map do |task_id, dependencies|
          task_id if dependencies.empty?
        end

        ready = [remaining.keys.first] if ready.empty?
        groups << ready
        ready.each { |task_id| remaining.delete(task_id) }
        ready_set = ready.to_set
        remaining.each_value(&.-(ready_set))
      end

      groups
    end
  end

  class SwarmResult
    include JSON::Serializable

    property plan : SwarmPlan
    property completed_tasks : Array(SwarmTask)
    property failed_tasks : Array(SwarmTask)
    property conflicts : Array(FileConflict)
    property total_cost_usd : Float64
    property total_duration_ms : Int32
    property agents_used : Int32

    def initialize(
      @plan : SwarmPlan,
      @completed_tasks : Array(SwarmTask),
      @failed_tasks : Array(SwarmTask),
      @conflicts : Array(FileConflict),
      @total_cost_usd : Float64,
      @total_duration_ms : Int32,
      @agents_used : Int32,
    )
    end
  end

  class TaskReview
    include JSON::Serializable

    property task_id : String
    property score : Int32
    property issues : Array(String)
    property suggestions : Array(String)

    def initialize(
      @task_id : String,
      @score : Int32 = 0,
      @issues : Array(String) = [] of String,
      @suggestions : Array(String) = [] of String,
    )
    end
  end

  class QualityReport
    include JSON::Serializable

    property overall_score : Int32
    property verdict : String
    property summary : String
    property task_reviews : Array(TaskReview)
    property integration_issues : Array(String)
    property missing_items : Array(String)
    property review_cost_usd : Float64

    def initialize(
      @overall_score : Int32 = 0,
      @verdict : String = "pass",
      @summary : String = "",
      @task_reviews : Array(TaskReview) = [] of TaskReview,
      @integration_issues : Array(String) = [] of String,
      @missing_items : Array(String) = [] of String,
      @review_cost_usd : Float64 = 0.0,
    )
    end
  end

  class SessionEvent
    include JSON::Serializable

    property timestamp : Float64
    property event_type : String
    property agent_id : String?
    property task_id : String?
    property data : Hash(String, JSON::Any)

    def initialize(
      @timestamp : Float64,
      @event_type : String,
      @agent_id : String? = nil,
      @task_id : String? = nil,
      @data : Hash(String, JSON::Any) = Hash(String, JSON::Any).new,
    )
    end
  end
end
