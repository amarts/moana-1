require "json"
require "db"

module MoanaTypes
  struct Node
    include JSON::Serializable
    include DB::Serializable

    property id = "", hostname = "", endpoint = "", cluster_id = "", token = ""

    def initialize
    end

    def initialize(@id, @hostname, @endpoint)
    end
  end

  struct Cluster
    include JSON::Serializable

    getter id, name
    property nodes = [] of MoanaTypes::Node

    def initialize(@id : String, @name : String)
    end
  end

  struct Task
    include JSON::Serializable
    include DB::Serializable

    property id : String, cluster_id : String, node_id : String, type : String, state : String, data : String, response : String, node = MoanaTypes::Node.new
  end

  struct Brick
    include JSON::Serializable

    property id = "",
             path = "",
             device = "",
             node = MoanaTypes::Node.new,
             port : Int32 = 0,
             state = "",
             type = ""

    def initialize
    end
  end

  struct Subvol
    include JSON::Serializable

    property replica_count : Int32 = 1,
             disperse_count : Int32 = 1,
             type = "",
             bricks = [] of MoanaTypes::Brick

    def initialize
    end
  end

  struct Volume
    include JSON::Serializable

    property id = "",
             name = "",
             replica_count : Int32 = 1,
             disperse_count : Int32 = 1,
             state = "",
             type = "",
             brick_fs = "",
             fs_opts = "",
             options = {} of String => String,
             subvols = [] of MoanaTypes::Subvol

    def initialize
    end

    def participating_nodes
      node_ids = [] of String
      @subvols.each do |subvol|
        subvol.bricks.each do |brick|
          node_ids << brick.node.id
        end
      end

      node_ids
    end

    def first_node_id
      node_id = ""
      @subvols.each do |subvol|
        subvol.bricks.each do |brick|
          node_id = brick.node.id
          break
        end
      end

      node_id
    end
  end

  struct Error
    include JSON::Serializable

    property error : String, status_code : Int32 = 0
  end

  struct Volfile
    include JSON::Serializable

    property content : String
  end

  struct Role
    include JSON::Serializable

    property user_id = "",
             cluster_id = "",
             volume_id = "",
             name = ""

    def initialize(@user_id, @cluster_id, @volume_id, @name)
    end
  end

  struct User
    include JSON::Serializable

    property id : String,
             name : String,
             email : String,
             roles = [] of MoanaTypes::Role

    def initialize(@id, @name, @email)
    end
  end

  struct App
    include JSON::Serializable
    include DB::Serializable

    property id : String,
             user_id : String,
             token : String = "",
             remote_ip : String,
             user_agent : String

    # TODO: Fix the Time Format https://github.com/crystal-lang/crystal-sqlite3/issues/14
    # created_at : String = ""

    def initialize(@id, @user_id, @token, @remote_ip, @user_agent)
    end
  end

  struct Token
    include JSON::Serializable

    property token = ""
  end
end
