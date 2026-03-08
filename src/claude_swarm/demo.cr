module ClaudeSwarm
  module Demo
    TOOL_SEQUENCES = {
      "coder"      => ["Read", "Grep", "Glob", "Read", "Write", "Edit", "Read", "Edit", "Bash"],
      "tester"     => ["Read", "Glob", "Write", "Bash", "Edit", "Bash"],
      "reviewer"   => ["Read", "Grep", "Glob", "Read", "Grep", "Read"],
      "refactorer" => ["Read", "Grep", "Read", "Edit", "Edit", "Bash"],
      "documenter" => ["Read", "Glob", "Write", "Edit"],
    }

    def self.build_plan(scenario_key : String? = nil) : SwarmPlan
      case scenario_key
      when "api"
        SwarmPlan.new(
          original_prompt: "Build a REST API for user management with CRUD operations",
          tasks: [
            SwarmTask.new(
              id: "task-1",
              description: "Create user model and database schema",
              agent_type: "coder",
              files_to_modify: ["src/models/user.ts", "prisma/schema.prisma"],
              tools: ["Read", "Write", "Edit", "Bash"],
              prompt: "Demo prompt for creating the model"
            ),
            SwarmTask.new(
              id: "task-2",
              description: "Implement CRUD API endpoints",
              agent_type: "coder",
              dependencies: ["task-1"],
              files_to_modify: ["src/app/api/users/route.ts", "src/app/api/users/[id]/route.ts"],
              tools: ["Read", "Write", "Edit", "Bash"],
              prompt: "Demo prompt for implementing the endpoints"
            ),
            SwarmTask.new(
              id: "task-3",
              description: "Add input validation with Zod schemas",
              agent_type: "coder",
              dependencies: ["task-1"],
              files_to_modify: ["src/lib/validators.ts"],
              tools: ["Read", "Write", "Edit"],
              prompt: "Demo prompt for validation"
            ),
            SwarmTask.new(
              id: "task-4",
              description: "Write comprehensive tests for all endpoints",
              agent_type: "tester",
              dependencies: ["task-2", "task-3"],
              files_to_modify: ["tests/users.test.ts"],
              tools: ["Read", "Write", "Edit", "Bash"],
              prompt: "Demo prompt for tests"
            ),
          ]
        )
      else
        SwarmPlan.new(
          original_prompt: "Refactor auth module from Express middleware to Next.js API routes",
          tasks: [
            SwarmTask.new(
              id: "task-1",
              description: "Create Next.js API route handlers for login/logout/register",
              agent_type: "coder",
              files_to_modify: ["src/app/api/auth/login/route.ts", "src/app/api/auth/register/route.ts"],
              tools: ["Read", "Write", "Edit", "Bash", "Grep", "Glob"],
              prompt: "Demo prompt for auth routes"
            ),
            SwarmTask.new(
              id: "task-2",
              description: "Migrate session management from Express to NextAuth.js",
              agent_type: "coder",
              files_to_modify: ["src/lib/auth.ts", "src/app/api/auth/[...nextauth]/route.ts"],
              tools: ["Read", "Write", "Edit", "Bash"],
              prompt: "Demo prompt for session management"
            ),
            SwarmTask.new(
              id: "task-3",
              description: "Update middleware for Next.js edge runtime",
              agent_type: "coder",
              dependencies: ["task-1"],
              files_to_modify: ["src/middleware.ts"],
              tools: ["Read", "Write", "Edit"],
              prompt: "Demo prompt for middleware"
            ),
            SwarmTask.new(
              id: "task-4",
              description: "Write integration tests for auth endpoints",
              agent_type: "tester",
              dependencies: ["task-1", "task-2"],
              files_to_modify: ["tests/auth.test.ts"],
              tools: ["Read", "Write", "Edit", "Bash"],
              prompt: "Demo prompt for auth tests"
            ),
            SwarmTask.new(
              id: "task-5",
              description: "Security review of auth implementation",
              agent_type: "reviewer",
              dependencies: ["task-1", "task-2", "task-3"],
              prompt: "Demo prompt for security review"
            ),
          ]
        )
      end
    end

    def self.run_demo(
      ui : UI,
      prompt : String? = nil,
      scenario : String? = nil,
      speed : Float64 = 1.0,
      no_ui : Bool = false,
    ) : Nil
      plan = build_plan(scenario)
      plan.original_prompt = prompt.not_nil! unless prompt.nil?

      ui.print_line
      ui.print_line("Phase 1: Decomposing task with Opus 4.6...")
      sleep((1.5 / speed).seconds)
      ui.print_plan(plan)
      sleep((1.0 / speed).seconds)
      ui.print_line("Phase 2: Executing swarm...")

      agents = Hash(String, SwarmAgent).new
      conflicts = [] of FileConflict
      total_cost = 0.0

      unless no_ui
        ui.start_live
      end

      begin
        plan.parallel_groups.each do |group|
          wave_agents = [] of Tuple(SwarmTask, SwarmAgent)
          group.each do |task_id|
            task = plan.tasks.find { |entry| entry.id == task_id }
            next unless task

            task.status = TaskStatus::Running
            agent = SwarmAgent.new(
              id: "agent-#{task.id}",
              name: "#{task.agent_type}-#{task.id}",
              task_id: task.id,
              status: AgentStatus::Working
            )
            agents[agent.id] = agent
            wave_agents << {task, agent}
          end

          max_tools = wave_agents.map { |task, _agent| TOOL_SEQUENCES[task.agent_type]?.try(&.size) || 1 }.max? || 1
          max_tools.times do |tool_index|
            wave_agents.each do |task, agent|
              tools = TOOL_SEQUENCES[task.agent_type]? || ["Read"]
              next unless tool_index < tools.size

              agent.current_tool = tools[tool_index]
              agent.turns = tool_index + 1
              increment = rand * 0.007 + 0.001
              agent.cost_usd += increment
              task.cost_usd = agent.cost_usd
            end
            total_cost = agents.values.sum(&.cost_usd)
            ui.update_live(ui.render_dashboard(plan, agents, total_cost, conflicts)) unless no_ui
            sleep((0.4 / speed).seconds)
          end

          wave_agents.each do |task, agent|
            task.status = TaskStatus::Completed
            task.duration_ms = rand(3000..12000).to_i32
            agent.status = AgentStatus::Completed
            agent.current_tool = nil
          end
          total_cost = agents.values.sum(&.cost_usd)
          ui.update_live(ui.render_dashboard(plan, agents, total_cost, conflicts)) unless no_ui
          sleep((0.8 / speed).seconds)
        end
      ensure
        ui.stop_live unless no_ui
      end

      result = SwarmResult.new(
        plan: plan,
        completed_tasks: plan.tasks.select(&.status.completed?),
        failed_tasks: [] of SwarmTask,
        conflicts: conflicts,
        total_cost_usd: total_cost,
        total_duration_ms: plan.tasks.sum(&.duration_ms),
        agents_used: agents.size.to_i32
      )

      ui.print_line("Phase 3: Results")
      ui.print_results(result)
      ui.print_line("Demo complete. Run without --demo to execute against a real agent runtime.")
    end
  end
end
