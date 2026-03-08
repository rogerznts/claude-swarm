require "option_parser"

module ClaudeSwarm
  class CLI
    struct RootOptions
      property cwd : String = "."
      property max_agents : Int32 = 4
      property model : String = "opus"
      property dry_run : Bool = false
      property no_ui : Bool = false
      property budget : Float64 = 5.0
      property config : String? = nil
      property demo : Bool = false
      property quality_gate : Bool = true
      property retry : Int32 = 1
      property version : Bool = false
      property scenario : String? = nil
    end

    def self.run(
      argv : Array(String) = ARGV.dup,
      runtime : AgentRuntime = SubprocessAgentRuntime.new,
      stdout : IO = STDOUT,
      stderr : IO = STDERR,
    ) : Nil
      if argv.first? == "sessions"
        run_sessions(argv[1..], stdout)
        return
      elsif argv.first? == "replay"
        run_replay(argv[1..], stdout, stderr)
        return
      end

      options = RootOptions.new
      args = argv.dup
      show_help = false

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: claude-swarm [options] TASK"
        opts.on("-d CWD", "--cwd=CWD", "Working directory for the project") { |value| options.cwd = value }
        opts.on("-n MAX", "--max-agents=MAX", "Maximum concurrent agents") { |value| options.max_agents = value.to_i }
        opts.on("-m MODEL", "--model=MODEL", "Model for task decomposition") { |value| options.model = value }
        opts.on("--dry-run", "Show plan without executing") { options.dry_run = true }
        opts.on("--no-ui", "Disable terminal dashboard") { options.no_ui = true }
        opts.on("-b BUDGET", "--budget=BUDGET", "Maximum total budget in USD") { |value| options.budget = value.to_f64 }
        opts.on("-c PATH", "--config=PATH", "Path to swarm.yaml config file") { |value| options.config = value }
        opts.on("--demo", "Run demo simulation") { options.demo = true }
        opts.on("--scenario=NAME", "Demo scenario (auth or api)") { |value| options.scenario = value }
        opts.on("--quality-gate", "Enable Opus quality review") { options.quality_gate = true }
        opts.on("--no-quality-gate", "Disable Opus quality review") { options.quality_gate = false }
        opts.on("-r RETRY", "--retry=RETRY", "Max retries for failed tasks") { |value| options.retry = value.to_i }
        opts.on("-v", "--version", "Show version") { options.version = true }
        opts.on("-h", "--help", "Show help") do
          show_help = true
        end
      end

      parser.parse(args)

      if show_help
        stdout.puts(parser)
        stdout.puts
        stdout.puts("Subcommands:")
        stdout.puts("  claude-swarm sessions")
        stdout.puts("  claude-swarm replay <session-id>")
        return
      end

      if options.version
        stdout.puts("claude-swarm v#{VERSION}")
        return
      end

      ui = UI.new(stdout, stdout.tty?)

      if options.demo
        demo_prompt = args.join(" ").strip
        Demo.run_demo(
          ui,
          prompt: demo_prompt.empty? ? nil : demo_prompt,
          scenario: options.scenario,
          no_ui: options.no_ui
        )
        return
      end

      task = args.join(" ").strip
      if task.empty?
        stdout.puts("Usage: claude-swarm <task description>")
        stdout.puts("       claude-swarm --help for options")
        stdout.puts("       claude-swarm --demo  # Live demo")
        stdout.puts("       claude-swarm sessions  # List past sessions")
        return
      end

      resolved_cwd = File.expand_path(options.cwd)
      run_swarm(task, resolved_cwd, options, ui, runtime)
    rescue error
      stderr.puts("claude-swarm error: #{error.message || error}")
    end

    private def self.run_sessions(args : Array(String), stdout : IO) : Nil
      limit = 20
      OptionParser.parse(args) do |opts|
        opts.banner = "Usage: claude-swarm sessions [options]"
        opts.on("-l LIMIT", "--limit=LIMIT", "Number of sessions to show") { |value| limit = value.to_i }
      end

      sessions = ClaudeSwarm.list_sessions(limit.to_i32)
      if sessions.empty?
        stdout.puts("No sessions found. Run a swarm first!")
        return
      end

      stdout.puts
      stdout.puts(sprintf("%-20s %-50s %-10s %-10s", "ID", "Prompt", "Duration", "Cost"))
      stdout.puts("-" * 95)
      sessions.each do |session|
        duration = session["duration_s"]?
        duration_str = duration && !duration.raw.nil? ? "%.1fs" % duration.as_f : "-"
        result = session["result"]?.try(&.as_h) || Hash(String, JSON::Any).new
        cost_str = if cost = result["total_cost_usd"]?
                     "$%.4f" % cost.as_f
                   else
                     "-"
                   end
        stdout.puts(sprintf(
          "%-20s %-50s %-10s %-10s",
          session["session_id"].as_s,
          session["prompt"].as_s,
          duration_str,
          cost_str
        ))
      end
      stdout.puts
    end

    private def self.run_replay(args : Array(String), stdout : IO, stderr : IO) : Nil
      session_id = args.first?
      unless session_id
        stderr.puts("Usage: claude-swarm replay <session-id>")
        return
      end

      events = ClaudeSwarm.load_session_events(session_id)
      if events.empty?
        stderr.puts("Session not found: #{session_id}")
        return
      end

      stdout.puts
      stdout.puts("Replaying session: #{session_id}")
      stdout.puts

      events.each do |event|
        timestamp = "%8.2fs" % event["timestamp"].as_f
        event_type = event["event_type"].as_s
        agent = event["agent_id"]?.try(&.as_s) || ""
        task = event["task_id"]?.try(&.as_s) || ""
        data = event["data"]?.try(&.as_h) || Hash(String, JSON::Any).new

        case event_type
        when "session_started"
          stdout.puts("#{timestamp} SESSION START #{data["prompt"]?.try(&.as_s).to_s[0, Math.min(data["prompt"]?.try(&.as_s).to_s.size, 60)]}")
        when "plan_created"
          stdout.puts("#{timestamp} PLAN CREATED #{data["tasks"]?.try(&.as_a.size) || 0} tasks")
        when "agent_started"
          stdout.puts("#{timestamp} AGENT START  #{agent} -> #{task} (#{data["description"]?.try(&.as_s).to_s[0, Math.min(data["description"]?.try(&.as_s).to_s.size, 40)]})")
        when "tool_use"
          stdout.puts("#{timestamp} TOOL USE     #{agent}: #{data["tool"]?.try(&.as_s) || "?"}")
        when "agent_completed"
          stdout.puts("#{timestamp} AGENT DONE   #{agent} ($#{format_cost(data["cost_usd"]?.try(&.as_f) || 0.0)}, #{data["duration_ms"]?.try(&.as_i) || 0}ms)")
        when "agent_failed"
          stdout.puts("#{timestamp} AGENT FAIL   #{agent}: #{data["error"]?.try(&.as_s).to_s[0, Math.min(data["error"]?.try(&.as_s).to_s.size, 60)]}")
        when "file_conflict"
          stdout.puts("#{timestamp} CONFLICT     #{data["file_path"]?.try(&.as_s) || ""}")
        when "quality_gate"
          stdout.puts("#{timestamp} QUALITY GATE Score: #{data["overall_score"]?.try(&.as_i) || "?"}/10 | Verdict: #{data["verdict"]?.try(&.as_s) || "?"}")
        when "session_completed"
          stdout.puts("#{timestamp} SESSION END  Total cost: $#{format_cost(data["total_cost_usd"]?.try(&.as_f) || 0.0)}")
        end
      end

      stdout.puts
    end

    private def self.run_swarm(
      task : String,
      cwd : String,
      options : RootOptions,
      ui : UI,
      runtime : AgentRuntime,
    ) : Nil
      swarm_config = if config_path = options.config
                       SwarmConfig.from_file(config_path)
                     else
                       ClaudeSwarm.find_config(cwd)
                     end

      if swarm_config
        ui.print_line("Loaded config: #{swarm_config.name}")
        options.max_agents = swarm_config.max_concurrent
        options.budget = swarm_config.budget_usd
        options.model = swarm_config.model
      end

      recorder = SessionRecorder.new
      recorder.start(task, cwd)

      ui.print_line("Phase 1: Decomposing task with Opus 4.6...")
      plan = Decomposer.decompose_task(task, cwd, options.model, runtime)
      ui.print_plan(plan)
      recorder.record_plan({
        "tasks" => JSON::Any.new(plan.tasks.map do |entry|
          JSON::Any.new({
            "id"           => JSON::Any.new(entry.id),
            "description"  => JSON::Any.new(entry.description),
            "agent_type"   => JSON::Any.new(entry.agent_type),
            "dependencies" => JSON::Any.new(entry.dependencies.map { |dependency| JSON::Any.new(dependency) }),
          })
        end),
      })

      if options.dry_run
        ui.print_line("Dry run - not executing tasks")
        session_path = recorder.finish({"dry_run" => JSON::Any.new(true)})
        ui.print_line("Session saved: #{session_path}")
        return
      end

      ui.print_line("Ready to execute #{plan.task_count} tasks with up to #{options.max_agents} concurrent agents.")
      features = [] of String
      features << "quality gate" if options.quality_gate
      features << "up to #{options.retry} retries" if options.retry > 1
      feature_suffix = features.empty? ? "" : " | Features: #{features.join(", ")}"
      ui.print_line("Budget: $#{format_cost(options.budget)} | Session: #{recorder.session_id}#{feature_suffix}")
      ui.print_line("Phase 2: Executing swarm...")

      orchestrator = SwarmOrchestrator.new(
        plan: plan,
        cwd: cwd,
        max_concurrent: options.max_agents,
        max_budget_usd: options.budget,
        recorder: recorder,
        max_retries: options.retry,
        runtime: runtime
      )

      result = if options.no_ui
                 orchestrator.run
               else
                 ui.start_live
                 begin
                   orchestrator.on_update = -> {
                     ui.update_live(ui.render_dashboard(plan, orchestrator.agents, orchestrator.total_cost, orchestrator.conflicts))
                   }
                   orchestrator.run
                 ensure
                   ui.stop_live
                 end
               end

      quality_report = nil
      if options.quality_gate && !result.completed_tasks.empty?
        ui.print_line("Phase 2.5: Opus 4.6 Quality Gate...")
        begin
          quality_report = QualityGate.run(result, cwd, options.model, runtime)
          result.total_cost_usd += quality_report.not_nil!.review_cost_usd
          recorder.record_quality_gate(quality_report.not_nil!)
        rescue error
          ui.print_line("Quality gate skipped: #{error.message || error}")
        end
      end

      ui.print_line("Phase 3: Results")
      ui.print_results(result)
      ui.print_quality_report(quality_report.not_nil!) if quality_report

      session_data = {
        "completed"         => JSON::Any.new(result.completed_tasks.size),
        "failed"            => JSON::Any.new(result.failed_tasks.size),
        "total_cost_usd"    => JSON::Any.new(result.total_cost_usd),
        "total_duration_ms" => JSON::Any.new(result.total_duration_ms),
        "agents_used"       => JSON::Any.new(result.agents_used),
        "conflicts"         => JSON::Any.new(result.conflicts.size),
      }
      if report = quality_report
        session_data["quality_score"] = JSON::Any.new(report.overall_score)
        session_data["quality_verdict"] = JSON::Any.new(report.verdict)
      end

      session_path = recorder.finish(session_data)
      ui.print_line("Session saved: #{session_path}")
      ui.print_line("Replay with: claude-swarm replay #{recorder.session_id}")
    end

    private def self.format_cost(value : Float64) : String
      "%.4f" % value
    end
  end
end
