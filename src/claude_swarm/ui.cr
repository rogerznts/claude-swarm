module ClaudeSwarm
  class UI
    getter output : IO

    @live : Bool
    @color : Bool
    @start_time : Time::Instant

    def initialize(@output : IO = STDOUT, @color : Bool = false)
      @live = false
      @start_time = Time.instant
    end

    def print_line(text : String = "") : Nil
      @output.puts(text)
    end

    def print_plan(plan : SwarmPlan) : Nil
      print_line
      print_line(colorize("Claude Swarm", "34;1"))
      print_line(plan.original_prompt)
      print_line("#{plan.task_count} tasks | model: #{plan.model_used}")
      print_line
      print_line("Task Plan")
      print_line("ID         Type         Depends On           Files")
      print_line("-" * 78)
      plan.tasks.each do |task|
        deps = task.dependencies.empty? ? "-" : task.dependencies.join(", ")
        files = task.files_to_modify.empty? ? "-" : task.files_to_modify[0, 3].join(", ")
        files += " +#{task.files_to_modify.size - 3}" if task.files_to_modify.size > 3
        print_line("#{pad(task.id, 10)} #{pad(task.agent_type, 12)} #{pad(deps, 20)} #{files}")
        print_line("           #{task.description}")
      end
      print_line
      print_line("Execution Order:")
      plan.parallel_groups.each_with_index do |group, index|
        print_line("Wave #{index + 1}: [#{group.join(" | ")}]")
      end
      print_line
    end

    def render_dashboard(
      plan : SwarmPlan,
      agents : Hash(String, SwarmAgent),
      total_cost : Float64,
      conflicts : Array(FileConflict),
    ) : String
      elapsed = (Time.instant - @start_time).total_seconds
      completed = plan.tasks.count(&.status.completed?)
      running = plan.tasks.count(&.status.running?)
      failed = plan.tasks.count(&.status.failed?)

      String.build do |io|
        io << colorize("Claude Swarm", "34;1")
        io << " | Tasks: #{completed}/#{plan.task_count} done"
        io << " | Running: #{running}"
        io << " | Failed: #{failed}" if failed > 0
        io << " | Cost: $#{format_cost(total_cost)}"
        io << " | Time: #{elapsed.round}s\n\n"

        io << "Tasks\n"
        io << "ID         Status Type       Cost     Description\n"
        io << "-" * 78 << '\n'
        plan.tasks.each do |task|
          io << "#{pad(task.id, 10)} #{pad(task_status_label(task.status), 6)} #{pad(task.agent_type, 10)} "
          io << "#{pad(task.cost_usd > 0 ? "$#{format_cost(task.cost_usd)}" : "-", 8)} "
          io << task.description[0, Math.min(task.description.size, 45)] << '\n'
        end

        io << "\nAgents\n"
        io << "Agent              Status    Tool            Turns Cost\n"
        io << "-" * 78 << '\n'
        agents.values.each do |agent|
          io << "#{pad(agent.name, 18)} #{pad(agent_status_label(agent.status), 9)} "
          io << "#{pad(agent.current_tool || "-", 15)} #{pad(agent.turns.to_s, 5)} "
          io << "$#{format_cost(agent.cost_usd)}\n"
        end

        io << "\nConflicts\n"
        if conflicts.empty?
          io << "No file conflicts detected\n"
        else
          conflicts.first(3).each do |conflict|
            io << "#{conflict.file_path} (#{conflict.agent_ids.join(", ")})\n"
          end
        end
      end
    end

    def start_live : Nil
      @live = true
      @start_time = Time.instant
    end

    def update_live(content : String) : Nil
      return unless @live

      @output.print("\e[2J\e[H")
      @output.print(content)
      @output.flush
    end

    def stop_live : Nil
      return unless @live

      @live = false
      @output.puts
    end

    def print_quality_report(report : QualityReport) : Nil
      print_line
      print_line(colorize("Opus 4.6 Quality Gate", "35;1"))
      print_line("Score: #{report.overall_score}/10 | Verdict: #{report.verdict.upcase} | Review cost: $#{format_cost(report.review_cost_usd)}")
      print_line(report.summary)

      unless report.integration_issues.empty?
        print_line("Integration Issues:")
        report.integration_issues.each { |issue| print_line("  ! #{issue}") }
      end

      unless report.missing_items.empty?
        print_line("Missing Items:")
        report.missing_items.each { |item| print_line("  - #{item}") }
      end

      unless report.task_reviews.empty?
        print_line("Per-Task Reviews:")
        report.task_reviews.each do |review|
          issues = review.issues.empty? ? "-" : review.issues.first(2).join("; ")
          suggestions = review.suggestions.empty? ? "-" : review.suggestions.first(2).join("; ")
          print_line("  #{review.task_id} | score #{review.score} | issues: #{issues} | suggestions: #{suggestions}")
        end
      end
      print_line
    end

    def print_results(result : SwarmResult) : Nil
      print_line
      print_line("Swarm Results")
      print_line("-" * 40)
      completed = result.completed_tasks.size
      failed = result.failed_tasks.size
      cancelled = result.plan.tasks.count(&.status.cancelled?)
      total = result.plan.task_count
      success_rate = total.zero? ? 0.0 : (completed / total.to_f) * 100.0

      print_line("Tasks Completed : #{completed}")
      print_line("Tasks Failed    : #{failed}")
      print_line("Tasks Cancelled : #{cancelled}") if cancelled > 0
      print_line("Success Rate    : #{success_rate.round}%")
      print_line("Total Cost      : $#{format_cost(result.total_cost_usd)}")
      print_line("Duration        : #{(result.total_duration_ms / 1000.0).round(1)}s")
      print_line("Agents Used     : #{result.agents_used}")
      print_line("File Conflicts  : #{result.conflicts.size}")

      unless result.failed_tasks.empty?
        print_line
        print_line("Failed Tasks:")
        result.failed_tasks.each do |task|
          print_line("  #{task.id}: #{task.error}")
        end
      end

      print_line
    end

    private def colorize(text : String, code : String) : String
      return text unless @color

      "\e[#{code}m#{text}\e[0m"
    end

    private def pad(text : String, width : Int32) : String
      text.size >= width ? text[0, width] : text + (" " * (width - text.size))
    end

    private def task_status_label(status : TaskStatus) : String
      case status
      in .pending?   then "..."
      in .blocked?   then "BLK"
      in .running?   then "RUN"
      in .completed? then "OK"
      in .failed?    then "ERR"
      in .cancelled? then "CXL"
      end
    end

    private def agent_status_label(status : AgentStatus) : String
      case status
      in .idle?      then "idle"
      in .working?   then "working"
      in .blocked?   then "blocked"
      in .completed? then "done"
      in .failed?    then "failed"
      end
    end

    private def format_cost(value : Float64) : String
      "%.4f" % value
    end
  end
end
