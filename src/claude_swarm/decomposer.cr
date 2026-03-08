module ClaudeSwarm
  DECOMPOSE_SYSTEM_PROMPT = <<-TEXT
  You are a task decomposition expert.
  Given a complex software engineering task, break it down into
  independent subtasks that can be executed by separate agents in parallel.

  RULES:
  1. Each subtask should be as independent as possible
  2. Specify dependencies between tasks (task IDs)
  3. Each task should specify which files it will modify
  4. Tasks should be small enough for one agent to complete in a few minutes
  5. Include a "reviewer" task at the end that depends on all implementation tasks

  OUTPUT FORMAT (strict JSON):
  {
    "tasks": [
      {
        "id": "task-1",
        "description": "Short description of what to do",
        "agent_type": "coder|reviewer|tester|refactorer|documenter",
        "dependencies": [],
        "files_to_modify": ["src/auth.ts", "src/middleware.ts"],
        "tools": ["Read", "Write", "Edit", "Bash", "Grep", "Glob"],
        "prompt": "Detailed instructions for the agent..."
      }
    ]
  }

  IMPORTANT:
  - Minimize file overlap between tasks to prevent conflicts
  - If two tasks MUST edit the same file, make one depend on the other
  - Keep the total number of tasks between 2 and 8
  - Each task's prompt should be self-contained with all context needed
  TEXT

  module Decomposer
    def self.decompose_task(
      prompt : String,
      cwd : String,
      model : String = "opus",
      runtime : AgentRuntime = SubprocessAgentRuntime.new,
    ) : SwarmPlan
      decompose_prompt = <<-TEXT
      #{DECOMPOSE_SYSTEM_PROMPT}

      PROJECT DIRECTORY: #{cwd}

      TASK TO DECOMPOSE:
      #{prompt}

      First, explore the codebase to understand the structure.
      Then output your decomposition as a JSON code block.
      TEXT

      result = runtime.run(
        decompose_prompt,
        RuntimeOptions.new(
          model: model,
          cwd: cwd,
          permission_mode: "default",
          max_turns: 3
        )
      )

      tasks = parse_decomposition(result.text)
      SwarmPlan.new(
        original_prompt: prompt,
        tasks: tasks,
        estimated_total_cost: result.total_cost_usd * tasks.size,
        model_used: model
      )
    end

    def self.parse_decomposition(text : String) : Array(SwarmTask)
      json_str = extract_json_block(text) || text.strip
      begin
        data = JSON.parse(json_str)
      rescue JSON::ParseException
        return [
          SwarmTask.new(
            id: "task-#{Random::Secure.hex(4)}",
            description: "Execute the original task (decomposition failed)",
            agent_type: "coder",
            prompt: text,
            tools: SwarmConfig.default_tools
          ),
        ]
      end

      tasks_any = if data.as_h?
                    data.as_h["tasks"]? || JSON::Any.new([] of JSON::Any)
                  else
                    data
                  end

      tasks_any.as_a.map do |item|
        data_hash = item.as_h
        SwarmTask.new(
          id: data_hash["id"]?.try(&.as_s) || "task-#{Random::Secure.hex(4)}",
          description: data_hash["description"]?.try(&.as_s) || "",
          agent_type: data_hash["agent_type"]?.try(&.as_s) || "coder",
          dependencies: data_hash["dependencies"]?.try(&.as_a.map(&.as_s)) || [] of String,
          files_to_modify: data_hash["files_to_modify"]?.try(&.as_a.map(&.as_s)) || [] of String,
          tools: data_hash["tools"]?.try(&.as_a.map(&.as_s)) || SwarmConfig.default_tools,
          prompt: data_hash["prompt"]?.try(&.as_s) || data_hash["description"]?.try(&.as_s) || "",
          status: TaskStatus::Pending
        )
      end
    end

    def self.extract_json_block(text : String) : String?
      ["```json\n", "```json\r\n", "```\n{"].each do |marker|
        start_index = text.index(marker)
        next unless start_index

        content_start = marker == "```\n{" ? start_index + 4 : start_index + marker.size
        end_index = text.index("```", content_start)
        return text[content_start...end_index].strip if end_index
      end

      extract_first_json_object(text)
    end

    private def self.extract_first_json_object(text : String) : String?
      start_index = text.index('{')
      return nil unless start_index

      depth = 0
      text.each_char_with_index do |char, index|
        next if index < start_index

        case char
        when '{' then depth += 1
        when '}'
          depth -= 1
          return text[start_index..index] if depth.zero?
        end
      end

      nil
    end
  end
end
