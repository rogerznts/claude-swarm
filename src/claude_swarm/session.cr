require "file_utils"

module ClaudeSwarm
  class SessionRecorder
    SESSIONS_DIR = File.join(ENV["HOME"]? || ".", ".claude-swarm", "sessions")

    getter session_id : String
    getter session_dir : String
    getter events : Array(SessionEvent)
    getter metadata : Hash(String, JSON::Any)

    @start_time : Time::Instant

    def initialize(@session_id : String = "swarm-#{Random::Secure.hex(6)}", @base_dir : String = SESSIONS_DIR)
      @session_dir = File.join(@base_dir, @session_id)
      @events = [] of SessionEvent
      @metadata = Hash(String, JSON::Any).new
      @start_time = Time.instant
    end

    def start(prompt : String, cwd : String) : Nil
      FileUtils.mkdir_p(@session_dir)
      @start_time = Time.instant
      @metadata = {
        "session_id" => JSON::Any.new(@session_id),
        "prompt"     => JSON::Any.new(prompt),
        "cwd"        => JSON::Any.new(cwd),
        "start_time" => JSON::Any.new(Time.utc.to_unix.to_f64),
      }
      record_event("session_started", data: {
        "prompt" => JSON::Any.new(prompt),
        "cwd"    => JSON::Any.new(cwd),
      })
    end

    def record_plan(plan_data : Hash(String, JSON::Any)) : Nil
      @metadata["plan"] = JSON::Any.new(plan_data)
      record_event("plan_created", data: plan_data)
    end

    def record_agent_started(agent_id : String, task_id : String, task_description : String) : Nil
      record_event(
        "agent_started",
        agent_id: agent_id,
        task_id: task_id,
        data: {"description" => JSON::Any.new(task_description)}
      )
    end

    def record_tool_use(
      agent_id : String,
      task_id : String,
      tool_name : String,
      tool_input : Hash(String, JSON::Any),
    ) : Nil
      record_event(
        "tool_use",
        agent_id: agent_id,
        task_id: task_id,
        data: {
          "tool"  => JSON::Any.new(tool_name),
          "input" => JSON::Any.new(truncate_input(tool_input)),
        }
      )
    end

    def record_agent_completed(agent_id : String, task_id : String, cost : Float64, duration_ms : Int32) : Nil
      record_event(
        "agent_completed",
        agent_id: agent_id,
        task_id: task_id,
        data: {
          "cost_usd"    => JSON::Any.new(cost),
          "duration_ms" => JSON::Any.new(duration_ms),
        }
      )
    end

    def record_agent_failed(agent_id : String, task_id : String, error : String) : Nil
      record_event(
        "agent_failed",
        agent_id: agent_id,
        task_id: task_id,
        data: {"error" => JSON::Any.new(error[0, Math.min(error.size, 500)])}
      )
    end

    def record_conflict(file_path : String, agent_ids : Array(String)) : Nil
      record_event(
        "file_conflict",
        data: {
          "file_path" => JSON::Any.new(file_path),
          "agent_ids" => JSON::Any.new(agent_ids.map { |agent_id| JSON::Any.new(agent_id) }),
        }
      )
    end

    def record_quality_gate(report : QualityReport) : Nil
      record_event(
        "quality_gate",
        data: {
          "overall_score"   => JSON::Any.new(report.overall_score),
          "verdict"         => JSON::Any.new(report.verdict),
          "summary"         => JSON::Any.new(report.summary),
          "review_cost_usd" => JSON::Any.new(report.review_cost_usd),
        }
      )
    end

    def finish(result_data : Hash(String, JSON::Any)) : String
      end_time = Time.utc.to_unix.to_f64
      @metadata["end_time"] = JSON::Any.new(end_time)
      @metadata["duration_s"] = JSON::Any.new((Time.instant - @start_time).total_seconds)
      @metadata["result"] = JSON::Any.new(result_data)

      record_event("session_completed", data: result_data)

      JsonHelpers.write_json_file(File.join(@session_dir, "metadata.json"), @metadata)
      File.open(File.join(@session_dir, "events.jsonl"), "w") do |file|
        @events.each do |event|
          file.puts(event.to_json)
        end
      end

      @session_dir
    end

    def record_event(
      event_type : String,
      agent_id : String? = nil,
      task_id : String? = nil,
      data : Hash(String, JSON::Any)? = nil,
    ) : Nil
      @events << SessionEvent.new(
        timestamp: (Time.instant - @start_time).total_seconds,
        event_type: event_type,
        agent_id: agent_id,
        task_id: task_id,
        data: data || Hash(String, JSON::Any).new
      )
    end

    private def truncate_input(tool_input : Hash(String, JSON::Any), max_len : Int32 = 200) : Hash(String, JSON::Any)
      tool_input.transform_values do |value|
        raw = value.raw
        if raw.is_a?(String) && raw.size > max_len
          JSON::Any.new("#{raw[0, max_len]}...")
        else
          value
        end
      end
    end
  end

  def self.list_sessions(limit : Int32 = 20, base_dir : String = SessionRecorder::SESSIONS_DIR) : Array(Hash(String, JSON::Any))
    return [] of Hash(String, JSON::Any) unless Dir.exists?(base_dir)

    sessions = [] of Hash(String, JSON::Any)
    entries = Dir.children(base_dir).sort.reverse
    entries.each do |entry|
      meta_path = File.join(base_dir, entry, "metadata.json")
      next unless File.exists?(meta_path)

      if metadata = JsonHelpers.read_json_file(meta_path)
        prompt = metadata["prompt"]?.try(&.as_s) || ""
        sessions << {
          "session_id" => JSON::Any.new(metadata["session_id"]?.try(&.as_s) || entry),
          "prompt"     => JSON::Any.new(prompt[0, Math.min(prompt.size, 80)]),
          "start_time" => metadata["start_time"]? || JSON::Any.new(nil),
          "duration_s" => metadata["duration_s"]? || JSON::Any.new(nil),
          "result"     => metadata["result"]? || JSON::Any.new(Hash(String, JSON::Any).new),
        }
      end

      break if sessions.size >= limit
    end

    sessions
  end

  def self.load_session_events(
    session_id : String,
    base_dir : String = SessionRecorder::SESSIONS_DIR,
  ) : Array(Hash(String, JSON::Any))
    events_path = File.join(base_dir, session_id, "events.jsonl")
    return [] of Hash(String, JSON::Any) unless File.exists?(events_path)

    events = [] of Hash(String, JSON::Any)
    File.each_line(events_path) do |line|
      content = line.strip
      next if content.empty?
      events << JSON.parse(content).as_h
    end

    events
  rescue JSON::ParseException
    [] of Hash(String, JSON::Any)
  end
end
