require "uuid"

module ClaudeSwarm
  class SwarmOrchestrator
    class AgentOutcome
      getter task_id : String
      getter agent_id : String
      getter result : RuntimeResult?
      getter duration_ms : Int32
      getter error_message : String?

      def initialize(
        @task_id : String,
        @agent_id : String,
        @result : RuntimeResult?,
        @duration_ms : Int32,
        @error_message : String? = nil,
      )
      end

      def success? : Bool
        !@result.nil? && @error_message.nil?
      end
    end

    property on_update : Proc(Nil)
    property on_agent_event : Proc(String, String, Hash(String, JSON::Any), Nil)

    getter plan : SwarmPlan
    getter cwd : String
    getter max_concurrent : Int32
    getter max_budget_usd : Float64
    getter max_retries : Int32
    getter agents : Hash(String, SwarmAgent)
    getter completed_task_ids : Set(String)
    getter conflicts : Array(FileConflict)
    getter total_cost : Float64

    @start_time : Time::Instant
    @budget_exceeded : Bool
    @retry_counts : Hash(String, Int32)
    @file_locks : Hash(String, String)
    @runtime : AgentRuntime
    @recorder : SessionRecorder?
    @tasks : Hash(String, SwarmTask)

    def initialize(
      @plan : SwarmPlan,
      @cwd : String,
      @max_concurrent : Int32 = 4,
      @max_budget_usd : Float64 = 5.0,
      @on_update : Proc(Nil) = -> { },
      @on_agent_event : Proc(String, String, Hash(String, JSON::Any), Nil) = ->(_a : String, _b : String, _c : Hash(String, JSON::Any)) { },
      @recorder : SessionRecorder? = nil,
      @max_retries : Int32 = 1,
      @runtime : AgentRuntime = SubprocessAgentRuntime.new,
    )
      @agents = Hash(String, SwarmAgent).new
      @completed_task_ids = Set(String).new
      @conflicts = [] of FileConflict
      @total_cost = 0.0
      @start_time = Time.instant
      @budget_exceeded = false
      @retry_counts = Hash(String, Int32).new
      @file_locks = Hash(String, String).new
      @tasks = @plan.tasks.to_h { |task| {task.id, task} }
    end

    def active_agent_count : Int32
      @agents.values.count(&.status.working?).to_i32
    end

    def run : SwarmResult
      @start_time = Time.instant
      completions = Channel(AgentOutcome).new(@max_concurrent)

      until all_done?
        cancel_tasks_with_failed_dependencies
        refresh_blocked_tasks
        enforce_budget_if_needed
        launch_ready_tasks(completions)

        break if all_done?

        if active_agent_count > 0
          apply_outcome(completions.receive)
        elsif runnable_tasks_stalled?
          cancel_stalled_tasks("No runnable tasks remain")
        else
          sleep 50.milliseconds
        end
      end

      while active_agent_count > 0
        apply_outcome(completions.receive)
      end

      elapsed = (Time.instant - @start_time).total_milliseconds.to_i
      SwarmResult.new(
        plan: @plan,
        completed_tasks: @plan.tasks.select(&.status.completed?),
        failed_tasks: @plan.tasks.select(&.status.failed?),
        conflicts: @conflicts,
        total_cost_usd: @total_cost,
        total_duration_ms: elapsed.to_i32,
        agents_used: @agents.size.to_i32
      )
    end

    def ready_tasks : Array(SwarmTask)
      @plan.tasks.select do |task|
        task.status.pending? && task.dependencies.all? { |dependency| @completed_task_ids.includes?(dependency) }
      end
    end

    def all_done? : Bool
      @plan.tasks.all? do |task|
        task.status.completed? || task.status.failed? || task.status.cancelled?
      end
    end

    def check_file_conflict(task : SwarmTask) : FileConflict?
      task.files_to_modify.each do |file_path|
        next unless other_agent_id = @file_locks[file_path]?

        if other_agent = @agents[other_agent_id]?
          if other_agent.status.working?
            return FileConflict.new(
              file_path: file_path,
              agent_ids: [other_agent_id, "pending"],
              task_ids: [other_agent.task_id, task.id]
            )
          end
        end
      end

      nil
    end

    def lock_files(task : SwarmTask) : Nil
      lock_id = task.assigned_agent || task.id
      task.files_to_modify.each do |file_path|
        @file_locks[file_path] = lock_id
      end
    end

    def unlock_files(task : SwarmTask) : Nil
      task.files_to_modify.each do |file_path|
        @file_locks.delete(file_path)
      end
    end

    def refresh_blocked_tasks : Nil
      @plan.tasks.each do |task|
        next unless task.status.blocked?
        next unless task.dependencies.all? { |dependency| @completed_task_ids.includes?(dependency) }
        next unless check_file_conflict(task).nil?

        task.status = TaskStatus::Pending
      end
    end

    def cancel_pending_tasks(reason : String) : Nil
      @plan.tasks.each do |task|
        next unless task.status.pending? || task.status.blocked?

        task.status = TaskStatus::Cancelled
        task.error = reason
      end
      @on_agent_event.call("orchestrator", "budget_exceeded", {"reason" => JSON::Any.new(reason)})
    end

    private def launch_ready_tasks(completions : Channel(AgentOutcome)) : Nil
      ready_tasks.each do |task|
        break if active_agent_count >= @max_concurrent
        next if @budget_exceeded

        agent_id = "agent-#{UUID.random.to_s[0, 8]}"
        task.assigned_agent = agent_id
        agent = SwarmAgent.new(
          id: agent_id,
          name: "#{task.agent_type}-#{task.id}",
          task_id: task.id,
          status: AgentStatus::Working
        )
        @agents[agent_id] = agent

        if conflict = check_file_conflict(task)
          @conflicts << conflict
          task.status = TaskStatus::Blocked
          @recorder.try(&.record_conflict(conflict.file_path, conflict.agent_ids))
          @agents.delete(agent_id)
          task.assigned_agent = nil
          @on_update.call
          next
        end

        task.status = TaskStatus::Running
        lock_files(task)
        emit_agent_event(agent_id, "started", {"task_id" => JSON::Any.new(task.id)})
        @recorder.try(&.record_agent_started(agent_id, task.id, task.description))
        @on_update.call

        spawn do
          completions.send(execute_agent(task, agent_id))
        end
      end
    end

    private def execute_agent(task : SwarmTask, agent_id : String) : AgentOutcome
      task_start = Time.instant
      begin
        result = @runtime.run(
          task.prompt,
          RuntimeOptions.new(
            model: "haiku",
            cwd: @cwd,
            permission_mode: "acceptEdits",
            max_turns: 20,
            max_budget_usd: 0.50,
            allowed_tools: task.tools
          )
        )
        AgentOutcome.new(
          task_id: task.id,
          agent_id: agent_id,
          result: result,
          duration_ms: (Time.instant - task_start).total_milliseconds.to_i.to_i32
        )
      rescue error
        AgentOutcome.new(
          task_id: task.id,
          agent_id: agent_id,
          result: nil,
          duration_ms: (Time.instant - task_start).total_milliseconds.to_i.to_i32,
          error_message: error.message || error.to_s
        )
      end
    end

    private def apply_outcome(outcome : AgentOutcome) : Nil
      task = @tasks[outcome.task_id]?
      return unless task
      agent = @agents[outcome.agent_id]?
      return unless agent

      if outcome.success?
        apply_success_outcome(task, agent, outcome)
      else
        apply_failure_outcome(task, agent, outcome.error_message || "unknown error")
      end
    ensure
      if task
        unlock_files(task)
        refresh_blocked_tasks
        cancel_tasks_with_failed_dependencies
        enforce_budget_if_needed
        @on_update.call
      end
    end

    private def apply_success_outcome(task : SwarmTask, agent : SwarmAgent, outcome : AgentOutcome) : Nil
      result = outcome.result.not_nil!
      result.tool_uses.each do |tool_use|
        agent.current_tool = tool_use.name
        agent.turns += 1
        emit_agent_event(
          agent.id,
          "tool_use",
          {
            "tool"  => JSON::Any.new(tool_use.name),
            "input" => JSON::Any.new(tool_use.input),
          }
        )
        @recorder.try(&.record_tool_use(agent.id, task.id, tool_use.name, tool_use.input))
        if file_path = tool_use.input["file_path"]?.try(&.as_s)
          agent.files_modified << file_path unless agent.files_modified.includes?(file_path)
        end
      end

      task.cost_usd = result.total_cost_usd
      @total_cost += task.cost_usd
      task.duration_ms = outcome.duration_ms
      task.result = result.text.rstrip
      task.status = TaskStatus::Completed
      @completed_task_ids << task.id

      agent.status = AgentStatus::Completed
      agent.cost_usd = task.cost_usd
      agent.current_tool = nil
      emit_agent_event(agent.id, "completed", {"cost" => JSON::Any.new(task.cost_usd)})
      @recorder.try(&.record_agent_completed(agent.id, task.id, task.cost_usd, task.duration_ms))
    end

    private def apply_failure_outcome(task : SwarmTask, agent : SwarmAgent, error_message : String) : Nil
      attempt = (@retry_counts[task.id]? || 0) + 1
      @retry_counts[task.id] = attempt
      agent.status = AgentStatus::Failed
      agent.current_tool = nil

      if attempt < @max_retries
        task.status = TaskStatus::Pending
        task.error = nil
        task.assigned_agent = nil
        emit_agent_event(
          agent.id,
          "retry",
          {
            "error"   => JSON::Any.new(error_message),
            "attempt" => JSON::Any.new(attempt),
          }
        )
        @recorder.try(&.record_agent_failed(agent.id, task.id, "Retry #{attempt}: #{error_message}"))
      else
        task.status = TaskStatus::Failed
        task.error = error_message
        emit_agent_event(agent.id, "failed", {"error" => JSON::Any.new(error_message)})
        @recorder.try(&.record_agent_failed(agent.id, task.id, error_message))
      end
    end

    private def enforce_budget_if_needed : Nil
      return unless @total_cost >= @max_budget_usd
      return if @budget_exceeded

      @budget_exceeded = true
      cancel_pending_tasks("Budget exceeded: $#{format_cost(@total_cost)} >= $#{format_cost(@max_budget_usd)}")
    end

    private def cancel_tasks_with_failed_dependencies : Nil
      failed_ids = @plan.tasks.select { |task| task.status.failed? || task.status.cancelled? }.map(&.id).to_set
      return if failed_ids.empty?

      @plan.tasks.each do |task|
        next unless task.status.pending? || task.status.blocked?
        next unless task.dependencies.any? { |dependency| failed_ids.includes?(dependency) }

        task.status = TaskStatus::Cancelled
        task.error = "Dependency failed"
      end
    end

    private def runnable_tasks_stalled? : Bool
      return false unless active_agent_count.zero?
      return false unless ready_tasks.empty?

      @plan.tasks.any? { |task| task.status.pending? || task.status.blocked? }
    end

    private def cancel_stalled_tasks(reason : String) : Nil
      @plan.tasks.each do |task|
        next unless task.status.pending? || task.status.blocked?

        task.status = TaskStatus::Cancelled
        task.error = reason
      end
      @on_update.call
    end

    private def emit_agent_event(agent_id : String, event_type : String, data : Hash(String, JSON::Any)) : Nil
      @on_agent_event.call(agent_id, event_type, data)
    end

    private def format_cost(value : Float64) : String
      "%.4f" % value
    end
  end
end
