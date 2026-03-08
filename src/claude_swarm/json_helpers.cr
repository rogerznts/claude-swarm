require "json"

module ClaudeSwarm
  module JsonHelpers
    def self.read_json_file(path : String) : Hash(String, JSON::Any)?
      return nil unless File.exists?(path)

      content = File.read(path)
      JSON.parse(content).as_h
    rescue JSON::ParseException
      nil
    end

    def self.write_json_file(path : String, data : Hash(String, JSON::Any)) : Nil
      File.write(path, data.to_pretty_json)
    end
  end
end
