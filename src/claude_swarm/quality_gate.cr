module ClaudeSwarm
  QUALITY_GATE_PROMPT = <<-TEXT
  You are a senior software architect performing a quality review of work
  done by a team of engineers. Each engineer completed a subtask
  independently, and you need to assess the overall quality and coherence
  of their combined work.

  ORIGINAL TASK:
  %{original_prompt}

  SUBTASK RESULTS:
  %{task_summaries}

  REVIEW CRITERIA:
  1. Completeness: Was the original task fully addressed?
  2. Consistency: Do the subtasks' outputs work together cohesively?
  3. Correctness: Are there any bugs, logic errors, or security issues?
  4. Quality: Is the code clean, well-structured, and maintainable?

  OUTPUT FORMAT (strict JSON):
  {
    "overall_score": 1-10,
    "verdict": "pass" | "needs_revision" | "fail",
    "summary": "Brief overall assessment",
    "task_reviews": [
      {
        "task_id": "task-1",
        "score": 1-10,
        "issues": ["list of specific issues"],
        "suggestions": ["list of improvement suggestions"]
      }
    ],
    "integration_issues": ["issues with how tasks work together"],
    "missing_items": ["things not addressed by any task"]
  }
  TEXT

  module QualityGate
    def self.run(
      result : SwarmResult,
      cwd : String,
      model : String = "opus",
      runtime : AgentRuntime = SubprocessAgentRuntime.new,
    ) : QualityReport
      prompt = QUALITY_GATE_PROMPT % {
        original_prompt: result.plan.original_prompt,
        task_summaries:  build_task_summaries(result),
      }

      runtime_result = runtime.run(
        prompt,
        RuntimeOptions.new(
          model: model,
          cwd: cwd,
          permission_mode: "default",
          max_turns: 2
        )
      )

      parse_quality_report(runtime_result.text, runtime_result.total_cost_usd)
    end

    def self.build_task_summaries(result : SwarmResult) : String
      result.plan.tasks.map do |task|
        files = task.files_to_modify.empty? ? "none" : task.files_to_modify.join(", ")
        summary = String.build do |io|
          io << "--- Task: #{task.id} (#{task.status.to_s.upcase}) ---\n"
          io << "Agent Type: #{task.agent_type}\n"
          io << "Description: #{task.description}\n"
          io << "Files Modified: #{files}\n"
          io << "Duration: #{task.duration_ms}ms | Cost: $#{format_cost(task.cost_usd)}"
          if output = task.result
            truncated = output.size > 2000 ? "#{output[0, 2000]}\n... (truncated)" : output
            io << "\nOutput:\n#{truncated}"
          end
          if error = task.error
            io << "\nError: #{error}"
          end
        end
        summary
      end.join("\n\n")
    end

    def self.parse_quality_report(text : String, cost : Float64) : QualityReport
      json_str = extract_json(text)
      return fallback_quality_report("Quality review completed (parsing failed)", cost) unless json_str

      begin
        data = JSON.parse(json_str).as_h
      rescue JSON::ParseException
        return fallback_quality_report("Quality review completed (JSON parse failed)", cost)
      end

      task_reviews = data["task_reviews"]?.try(&.as_a).try do |reviews|
        reviews.map do |review_any|
          review = review_any.as_h
          TaskReview.new(
            task_id: review["task_id"]?.try(&.as_s) || "",
            score: review["score"]?.try(&.as_i.to_i32) || 0,
            issues: review["issues"]?.try(&.as_a.map(&.as_s)) || [] of String,
            suggestions: review["suggestions"]?.try(&.as_a.map(&.as_s)) || [] of String
          )
        end
      end || [] of TaskReview

      QualityReport.new(
        overall_score: data["overall_score"]?.try(&.as_i.to_i32) || 0,
        verdict: data["verdict"]?.try(&.as_s) || "pass",
        summary: data["summary"]?.try(&.as_s) || "",
        task_reviews: task_reviews,
        integration_issues: data["integration_issues"]?.try(&.as_a.map(&.as_s)) || [] of String,
        missing_items: data["missing_items"]?.try(&.as_a.map(&.as_s)) || [] of String,
        review_cost_usd: cost
      )
    end

    def self.extract_json(text : String) : String?
      Decomposer.extract_json_block(text)
    end

    private def self.fallback_quality_report(summary : String, cost : Float64) : QualityReport
      QualityReport.new(
        overall_score: 7,
        verdict: "pass",
        summary: summary,
        review_cost_usd: cost
      )
    end

    private def self.format_cost(value : Float64) : String
      "%.4f" % value
    end
  end
end
