require "option_parser"

require "./clusters"
require "./nodes"
require "./volumes"
require "./tasks"
require "./volfile"
require "./helpers"
require "./users"

class MoanaCommands
  @args = Args.new
  @pos_args = [] of String
  @gflags = Gflags.new ENV.fetch("KADALU_MGMT_SERVER", "")
  @command_type = CommandType::Unknown
  @command : Command = UnknownCommand.new

  def parse
    parser = OptionParser.new do |parser|
      parser.banner = "Usage: #{COMMAND} <subcommand> [arguments]"

      cluster_commands parser
      node_commands parser
      volume_commands parser
      task_commands parser
      volfile_commands parser
      register_commands parser
      login_commands parser
      logout_commands parser
      apps_commands parser
      role_commands parser

      #parser.on("-v", "--verbose", "Enabled servose output") { verbose = true }
      parser.on("-h", "--help", "Show this help") do
        puts parser
        exit
      end

      parser.unknown_args do |args|
        @pos_args = args
      end

      parser.invalid_option do |flag|
        STDERR.puts "Invalid Option: #{flag}"
        exit 1
      end

      parser.missing_option do |flag|
        STDERR.puts "Missing Option: #{flag}"
        exit 1
      end

      parser.parse

      if @gflags.kadalu_mgmt_server == ""
        STDERR.puts "KADALU_MGMT_SERVER environment variable is not set"
        exit 1
      end
    end

    # Macro to create respective instance of Command struct and
    # call respective handle method. For example,
    # if @command_type == CommandType::VolumeCreate
    # then it creates @command = VolumeCreateCommand.new
    # Below things will be expanded as case statement like
    # case @command_type
    #   when Command::VolumeCreate
    #     @command = VolumeCreateCommand.new
    #   ...
    # end
    {% begin %}
      case @command_type
           {% for value in CommandType.constants %}
           when CommandType::{{ value }}
             @command = {{ value }}Command.new
           {% end %}
      end
    {% end %}

    # Pass global flags and arguments to respective Command instance
    @command.set_args(@gflags, @args, @pos_args)
    begin
      @command.handle
    rescue Socket::ConnectError
      STDERR.puts "Kadalu Management Server is not reachable. Please make sure environment variable KADALU_MGMT_SERVER=#{@gflags.kadalu_mgmt_server} is correct"
      exit 1
    end
  end
end

commands = MoanaCommands.new
commands.parse
