require "file_utils"

require "moana_types"
require "xattr"

require "../conf"
require "../services"
require "../datastore/*"
require "../default_volfiles"

VOLUME_ID_XATTR_NAME = "trusted.glusterfs.volume-id"
alias VolumeRequestToNode = Tuple(Hash(String, Array(MoanaTypes::ServiceUnit)), Hash(String, Array(MoanaTypes::Volfile)), MoanaTypes::Volume)

def volfile_get(name)
  # TODO: Add logic to read from the Templates directory
  case name
  when "client"
    CLIENT_VOLFILE
  when "storage_unit"
    STORAGE_UNIT_VOLFILE
  when "shd"
    SHD_VOLFILE
  else
    ""
  end
end

def participating_nodes(pool_name, req)
  case req
  when MoanaTypes::Volume
    nodes = [] of String
    req.distribute_groups.each do |dist_grp|
      dist_grp.storage_units.each do |storage_unit|
        nodes << storage_unit.node.name
      end
    end
    nodes.uniq!
    Datastore.get_nodes(pool_name, nodes)
  when Array(MoanaTypes::Volume)
    nodes = [] of MoanaTypes::Node
    req.each do |volume|
      nodes += participating_nodes(pool_name, volume)
    end
    nodes
  else
    [] of MoanaTypes::Node
  end
end

TEST_XATTR_NAME  = "user.testattr"
TEST_XATTR_VALUE = "testvalue"

def validate_volume_create(req)
  # TODO: Validate Rootdir
  req.distribute_groups.each do |dist_grp|
    dist_grp.storage_units.each do |storage_unit|
      next unless storage_unit.node.name == GlobalConfig.local_node.name

      unless File.exists?(Path[storage_unit.path].parent)
        return NodeResponse.new(false, {"error": "Storage unit parent directory(#{Path[storage_unit.path].parent}) not exists"}.to_json)
      end

      begin
        Dir.mkdir storage_unit.path
      rescue ex : Exception
        return NodeResponse.new(false, {"error": "Failed to create Storage unit path #{storage_unit.path} (Error: #{ex})"}.to_json)
      end

      begin
        xattr = XAttr.new(storage_unit.path)
        xattr[TEST_XATTR_NAME] = TEST_XATTR_VALUE
      rescue ex : IO::Error
        return NodeResponse.new(false, {"error": "Extended attributes are not supported for #{storage_unit.path} (Error: #{ex})"}.to_json)
      ensure
        FileUtils.rmdir storage_unit.path
      end
    end
  end

  NodeResponse.new(true, "")
end

def handle_node_volume_start_stop(data, action)
  services, volfiles, _ = VolumeRequestToNode.from_json(data)

  if action == "start" && !volfiles[GlobalConfig.local_node.name]?.nil?
    Dir.mkdir_p(Path.new(GlobalConfig.workdir, "volfiles"))
    volfiles[GlobalConfig.local_node.name].each do |volfile|
      File.write(Path.new(GlobalConfig.workdir, "volfiles", "#{volfile.name}.vol"), volfile.content)
    end
  end

  unless services[GlobalConfig.local_node.name]?.nil?
    # TODO: Hard coded path change?
    Dir.mkdir_p("/var/log/kadalu")
    Dir.mkdir_p("/var/run/kadalu")
    services[GlobalConfig.local_node.name].each do |service|
      svc = Service.from_json(service.to_json)
      if action == "start"
        svc.start
      else
        svc.stop
      end
    end
  end

  NodeResponse.new(true, "")
end

def handle_volume_create(data, stopped = false)
  services, volfiles, req = VolumeRequestToNode.from_json(data)
  resp = Hash(String, MoanaTypes::StorageUnit).new

  req.distribute_groups.each do |dist_grp|
    dist_grp.storage_units.each do |storage_unit|
      next unless storage_unit.node.name == GlobalConfig.local_node.name

      # Create the Storage Unit
      Dir.mkdir storage_unit.path

      # Set volume-id xattr, ignore if same Volume ID exists
      volume_id = UUID.new(req.id)
      begin
        xattr = XAttr.new(storage_unit.path, only_create: true)
        xattr[VOLUME_ID_XATTR_NAME] = volume_id.bytes.to_slice
      rescue ex : IO::Error
        if ex.os_error == Errno::EEXIST && xattr.not_nil![VOLUME_ID_XATTR_NAME] != volume_id.bytes.to_slice
          return NodeResponse.new(false, {"error": "Storage Unit #{storage_unit.node.name}:#{storage_unit.path} is already used with another Volume"}.to_json)
        else
          return NodeResponse.new(false, {"error": "Failed to set Volume ID Xattr. Error=#{ex}"}.to_json)
        end
      end

      # Create Meta directories
      Dir.mkdir_p "#{storage_unit.path}/.glusterfs/indices"

      # Collect and Update FS type and Size
      rc, out, err = execute("df", ["-B1", "--output=fstype,used,avail,iused,iavail", storage_unit.path])
      if rc == 0
        # Example output
        #     Used      Avail IUsed  IFree
        # 41259008 1021997056     3 524285
        _, line = out.strip.split("\n")
        fstype, used, avail, iused, ifree = line.split
        storage_unit.fs = fstype
        storage_unit.metrics.size_used_bytes = used.to_i64
        storage_unit.metrics.size_free_bytes = avail.to_i64
        storage_unit.metrics.size_bytes = used.to_i64 + avail.to_i64
        storage_unit.metrics.inodes_used_count = iused.to_i64
        storage_unit.metrics.inodes_free_count = ifree.to_i64
        storage_unit.metrics.inodes_count = iused.to_i64 + ifree.to_i64
      else
        Log.error &.emit("Failed to collect Storage Unit Metrics", storage_unit: "#{storage_unit.path}", rc: "#{rc}", error: "#{err.strip}")
      end
      resp[storage_unit.path] = storage_unit
    end
  end

  unless volfiles[GlobalConfig.local_node.name]?.nil?
    Dir.mkdir_p(Path.new(GlobalConfig.workdir, "volfiles"))
    volfiles[GlobalConfig.local_node.name].each do |volfile|
      File.write(Path.new(GlobalConfig.workdir, "volfiles", "#{volfile.name}.vol"), volfile.content)
    end
  end

  unless services[GlobalConfig.local_node.name]?.nil?
    # TODO: Hard coded path change?
    Dir.mkdir_p("/var/log/kadalu")
    Dir.mkdir_p("/var/run/kadalu")
    services[GlobalConfig.local_node.name].each do |service|
      svc = Service.from_json(service.to_json)
      svc.start
    end
  end

  NodeResponse.new(true, resp.to_json)
end

def node_details_add_to_volume(volume, nodes)
  nodes_lookup = Hash(String, MoanaTypes::Node).new

  nodes.each do |node|
    nodes_lookup[node.name] = node
  end

  volume.distribute_groups.each do |dist_grp|
    dist_grp.storage_units.each do |storage_unit|
      storage_unit.node = nodes_lookup[storage_unit.node.name]
    end
  end
end

def node_names(req)
  names = [] of String
  req.distribute_groups.each do |dist_grp|
    dist_grp.storage_units.each do |storage_unit|
      names << storage_unit.node.name
    end
  end

  names
end

def node_errors(message, node_responses)
  errs = MoanaTypes::Error.new(message)

  node_responses.each do |node_name, resp|
    unless resp.ok
      errs.node_errors << MoanaTypes::NodeError.new(
        node_name,
        resp.status_code,
        MoanaTypes::Error.from_json(resp.response).error
      )
    end
  end

  errs
end

def services_and_volfiles(req)
  services = Hash(String, Array(MoanaTypes::ServiceUnit)).new
  volfiles = Hash(String, Array(MoanaTypes::Volfile)).new

  return {services, volfiles} if req.no_start

  req.distribute_groups.each do |dist_grp|
    dist_grp.storage_units.each do |storage_unit|
      # Generate Service Unit
      service = StorageUnitService.new(req.name, storage_unit)
      services[storage_unit.node.name] = [] of MoanaTypes::ServiceUnit unless services[storage_unit.node.name]?

      services[storage_unit.node.name] << service.unit

      # Generate Storage Unit Volfile
      # TODO: Expose option as req.storage_unit_volfile_template
      tmpl = volfile_get("storage_unit")
      content = Volfile.storage_unit_level("storage_unit", tmpl, req, storage_unit.id)
      volfiles[storage_unit.node.name] = [] of MoanaTypes::Volfile unless volfiles[storage_unit.node.name]?
      volfiles[storage_unit.node.name] << MoanaTypes::Volfile.new(service.id, content)

      if req.replicate_family?
        # Generate Self-Heal service file
        # Generate Self-Heal Volfile
      end
    end
  end

  {services, volfiles}
end

def set_default_storage_unit_metrics(storage_unit)
  storage_unit.metrics.health = "Down"
end

def distribute_group_quorum(dist_grp)
  if dist_grp.replica_count > 0
    cnt = dist_grp.replica_count + dist_grp.arbiter_count
    (dist_grp.storage_units.size/cnt).ceil
  elsif dist_grp.disperse_count > 0
    dist_grp.disperse_count - dist_grp.redundancy_count
  else
    dist_grp.storage_units.size
  end
end

def distribute_group_health(dist_grp, up_storage_units_count)
  if up_storage_units_count == dist_grp.storage_units.size
    "Up"
  elsif up_storage_units_count >= distribute_group_quorum(dist_grp)
    "Partial"
  elsif up_storage_units_count > 0 && up_storage_units_count < distribute_group_quorum(dist_grp)
    "Degraded"
  else
    "Down"
  end
end

def volume_health(volume, up_dist_grps_count, down_dist_grps_count)
  if volume.distribute_groups.size == up_dist_grps_count
    "Up"
  elsif down_dist_grps_count > 0
    "Degraded"
  elsif up_dist_grps_count > 0
    "Partial"
  else
    "Down"
  end
end

def set_distribute_group_metrics(dist_grp)
  up_count = 0
  size_used_bytes : Int64 = 0
  size_free_bytes : Int64 = 0
  inodes_used_count : Int64 = 0
  inodes_free_count : Int64 = 0

  dist_grp.storage_units.each do |storage_unit|
    up_count += 1 if storage_unit.metrics.health == "Up"

    next if storage_unit.metrics.health == "Unknown"

    if dist_grp.replica_count > 0 || dist_grp.disperse_count > 0
      if size_used_bytes < storage_unit.metrics.size_used_bytes
        size_used_bytes = storage_unit.metrics.size_used_bytes
        size_free_bytes = storage_unit.metrics.size_free_bytes
        inodes_used_count = storage_unit.metrics.inodes_used_count
        inodes_free_count = storage_unit.metrics.inodes_free_count
      end
    else
      size_used_bytes += storage_unit.metrics.size_used_bytes
      size_free_bytes += storage_unit.metrics.size_free_bytes
      inodes_used_count += storage_unit.metrics.inodes_used_count
      inodes_free_count += storage_unit.metrics.inodes_free_count
    end
  end

  if dist_grp.disperse_count > 0
    # TODO: Calculate for disperse based on data and redundancy count
    data_count = (dist_grp.disperse_count - dist_grp.redundancy_count)
    size_used_bytes = size_used_bytes * data_count
    size_free_bytes = size_free_bytes * data_count
    inodes_used_count = inodes_used_count * data_count
    inodes_free_count = inodes_free_count * data_count
  end

  dist_grp.metrics.health = distribute_group_health(dist_grp, up_count)
  dist_grp.metrics.size_used_bytes = size_used_bytes
  dist_grp.metrics.size_free_bytes = size_free_bytes
  dist_grp.metrics.size_bytes = size_used_bytes + size_free_bytes
  dist_grp.metrics.inodes_used_count = inodes_used_count
  dist_grp.metrics.inodes_free_count = inodes_free_count
  dist_grp.metrics.inodes_count = inodes_used_count + inodes_free_count
end

def set_volume_metrics(volume)
  up_count : Int32 = 0
  down_count : Int32 = 0
  size_used_bytes : Int64 = 0
  size_free_bytes : Int64 = 0
  inodes_used_count : Int64 = 0
  inodes_free_count : Int64 = 0

  volume.distribute_groups.each do |dist_grp|
    next if dist_grp.metrics.health == "Unknown"

    set_distribute_group_metrics(dist_grp)
    up_count += 1 if dist_grp.metrics.health == "Up"
    down_count += 1 if dist_grp.metrics.health == "Down"

    size_used_bytes += dist_grp.metrics.size_used_bytes
    size_free_bytes += dist_grp.metrics.size_free_bytes
    inodes_used_count += dist_grp.metrics.inodes_used_count
    inodes_free_count += dist_grp.metrics.inodes_free_count
  end

  volume.metrics.health = volume_health(volume, up_count, down_count)
  volume.metrics.size_used_bytes = size_used_bytes
  volume.metrics.size_free_bytes = size_free_bytes
  volume.metrics.size_bytes = size_used_bytes + size_free_bytes
  volume.metrics.inodes_used_count = inodes_used_count
  volume.metrics.inodes_free_count = inodes_free_count
  volume.metrics.inodes_count = inodes_used_count + inodes_free_count
end
