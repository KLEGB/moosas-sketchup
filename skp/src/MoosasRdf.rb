# Local, lazy loader for the vendored RDF.rb stack.
#
# The libraries under skp/src/vendor/rdf are deliberately loaded from the
# plugin directory.  Nothing is installed into SketchUp's Ruby environment.
module MoosasRdf
  VENDOR_ROOT = File.expand_path(File.join(File.dirname(__FILE__), "vendor", "rdf")).freeze
  RDF_VERSION = "3.2.12".freeze
  RDF_TURTLE_VERSION = "3.2.1".freeze
  EBNF_VERSION = "2.3.5".freeze

  BOT = "https://w3id.org/bot#".freeze
  MOOSAS = "https://moosas#".freeze
  PGD = "http://www.hkust.edu.hk/zhaojiwu/performance_based_generative_design#".freeze
  RDF_NS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#".freeze

  class ModelError < StandardError
    attr_reader :code, :context

    def initialize(code, message, context = {})
      @code = code
      @context = context
      super("#{code}: #{message} #{context.inspect}")
    end
  end

  def self.load!
    unless $LOAD_PATH.include?(VENDOR_ROOT)
      $LOAD_PATH.unshift(VENDOR_ROOT)
    end

    require "rdf/turtle"
    true
  end

  def self.graph_from_turtle(path)
    load!
    graph = RDF::Graph.new
    File.open(path.to_s, "rb") do |file|
      RDF::Turtle::Reader.new(file) do |reader|
        reader.each_statement { |statement| graph << statement }
      end
    end
    graph
  end

  # Build the SketchUp-side Moosas object graph from the current Moosas RDF
  # format. Geometry is deliberately resolved through the transformed .geo
  # wrappers supplied by MMR; RDF remains the source of semantic topology.
  def self.build_model(graph, geometries:, entities: nil, strict: true)
    load!
    graph_index(graph)
    geometry_by_id = index_geometries(geometries)
    element_records = index_elements(graph, geometry_by_id, strict)
    spaces = build_spaces(graph, element_records, strict)
    raise ModelError.new(:empty_model, "RDF contains no valid spaces") if spaces.empty?

    model = MoosasModel.new(spaces)
    assign_semantic_materials(model, spaces)
    apply_rdf_element_types(element_records)
    attach_unbound_shading(model, geometries)
    model
  end

  def self.index_geometries(geometries)
    index = {}
    Array(geometries).each do |geometry|
      next if geometry.nil?
      id = geometry.id.to_s
      raise ModelError.new(:duplicate_geometry_id, "duplicate transformed geometry", id: id) if index.key?(id)
      index[id] = geometry
    end
    index
  end

  def self.index_elements(graph, geometry_by_id, strict)
    records = {}
    element_nodes(graph).each do |node|
      uid = literal(graph, node, uri(MOOSAS, "Uid"))
      fail_model(:missing_uid, "RDF element has no Uid", node: node) if strict && blank?(uid)
      next if blank?(uid)
      key = uid.to_s
      fail_model(:duplicate_uid, "duplicate RDF element Uid", uid: key) if strict && records.key?(key)

      face_ids = objects(graph, node, uri(MOOSAS, "hasFace")).map do |face_node|
        face_id = literal(graph, face_node, uri(MOOSAS, "faceId"))
        face_id = face_node.to_s if blank?(face_id)
        face_id.to_s
      end.uniq
      faces = face_ids.map do |face_id|
        geometry = geometry_by_id[face_id]
        fail_model(:missing_geometry, "RDF faceId has no transformed SketchUp face", uid: key, face_id: face_id) if geometry.nil? && strict
        geometry
      end.compact
      fail_model(:empty_element_geometry, "RDF element has no resolved geometry", uid: key) if faces.empty? && strict

      type_uri = first_object(graph, node, uri(PGD, "hasSurfaceType"))
      records[key] = {
        :node => node,
        :uid => key,
        :faces => faces,
        :type_uri => type_uri,
        :type_name => local_name(type_uri)
      }
      faces.each { |face| face.uid = key }
    end

    records.each_value do |parent|
      objects(graph, parent[:node], uri(BOT, "hasSubElement")).each do |child_node|
        child_uid = literal(graph, child_node, uri(MOOSAS, "Uid"))
        child = records[child_uid.to_s] unless blank?(child_uid)
        if child.nil?
          fail_model(:missing_glazing, "parent references an unknown sub-element", parent: parent[:uid], child: child_node) if strict
          next
        end
        child[:faces].each { |child_face| child_face.uid = child[:uid] }
        parent[:faces].each do |parent_face|
          parent_face.glazings = (parent_face.glazings + child[:faces]).uniq
        end
      end
    end
    records
  end

  def self.build_spaces(graph, records, strict)
    spaces = []
    node_to_space = {}
    subjects(graph, uri(RDF_NS, "type"), uri(BOT, "Space")).each do |space_node|
      uid = literal(graph, space_node, uri(MOOSAS, "Uid"))
      fail_model(:missing_space_uid, "RDF space has no Uid", node: space_node) if strict && blank?(uid)
      next if blank?(uid)
      void_space = void_space?(graph, space_node)
      interfaces = subjects(graph, uri(BOT, "interfaceOf"), space_node)
      floor = []
      ceiling = []
      edge_items = []

      interfaces.each do |interface_node|
        linked = objects(graph, interface_node, uri(BOT, "interfaceOf"))
        element_node = linked.find { |candidate| candidate.to_s != space_node.to_s }
        fail_model(:invalid_interface, "interface does not link to an element", space: uid, interface: interface_node) if element_node.nil? && strict
        next if element_node.nil?
        element_uid = literal(graph, element_node, uri(MOOSAS, "Uid"))
        record = records[element_uid.to_s]
        fail_model(:missing_interface_element, "interface element is not indexed", space: uid, element: element_uid) if record.nil? && strict
        next if record.nil?
        topology_type = first_object(graph, interface_node, uri(PGD, "hasSurfaceType"))
        topology_type = first_object(graph, interface_node, uri(PGD, "surfaceType")) if topology_type.nil?
        topology_name = local_name(topology_type)
        if topology_name == "Floor"
          floor.concat(record[:faces])
        elsif topology_name == "Ceiling"
          ceiling.concat(record[:faces])
        elsif topology_name == "Edge"
          order = numeric(first_object(graph, interface_node, uri(MOOSAS, "subElementOrder")), 0)
          edge_items << [order, record, interface_node]
        end
      end

      floor = floor.uniq
      ceiling = ceiling.uniq
      edge_items.sort_by! { |item| item[0] }
      if void_space
        fail_model(:empty_void_topology, "void has no boundary edges", space: uid.to_s) if strict && edge_items.empty?
        next if edge_items.empty?
      else
        fail_model(:incomplete_space, "space is missing floor, ceiling, or boundary edges", space: uid.to_s, floor: floor.length, ceiling: ceiling.length, edges: edge_items.length) if strict && (floor.empty? || ceiling.empty? || edge_items.empty?)
        next if floor.empty? || ceiling.empty? || edge_items.empty?
      end

      height_m = space_height_m(graph, space_node)
      height_in = height_m / MoosasConstant::INCH_METER_MULTIPLIER
      bounds = edge_items.map do |_order, record, interface_node|
        build_edge(record, interface_node, height_in, graph, strict)
      end
      bounds.compact!
      fail_model(:invalid_space_edges, "space has no valid boundary edges", space: uid.to_s) if strict && bounds.empty?
      next if bounds.empty?

      if void_space
        space = MoosasVoid.new(bounds, height_in, void_id_for(uid.to_s), uid.to_s)
      else
        space = MoosasSpace.new(floor, height_in, ceiling, bounds, uid.to_s)
      end
      space.is_outer = bounds.any? { |edge| !edge.is_internal_edge }
      objects(graph, space_node, uri(MOOSAS, 'hasSetting')).each do |key|
        raw = first_object(graph, space_node, uri(MOOSAS, key.to_s)) || first_object(graph, space_node, RDF::Literal.new(key.to_s))
        next unless raw
        space.settings[key.to_s] = raw.is_a?(RDF::Literal) ? raw.object : local_name(raw)
      end
      if space.settings.key?('zone_inflitration')
        space.settings['zone_infiltration'] ||= space.settings.delete('zone_inflitration')
        space.settings.delete('zone_inflitration')
      end
      space.instance_variable_set(:@explicit_settings, objects(graph, space_node, uri(MOOSAS, 'explicitSetting')).map(&:to_s))
      spaces << space
      node_to_space[space_node] = space
    end
    subjects(graph, uri(RDF_NS, "type"), uri(BOT, "Space")).each do |parent_node|
      parent = node_to_space[parent_node]
      next if parent.nil?
      objects(graph, parent_node, uri(BOT, "containsZone")).each do |child_node|
        child = node_to_space[child_node]
        next if child.nil? || !child.respond_to?(:is_void?) || !child.is_void?
        parent.contained_voids << child unless parent.contained_voids.include?(child)
        child.parent_space = parent
      end
    end
    spaces
  end

  def self.void_space?(graph, space_node)
    marker = first_object(graph, space_node, uri(MOOSAS, "isVoid"))
    return true if marker && ["true", "1", "yes"].include?(marker.to_s.downcase)
    type = first_object(graph, space_node, uri(MOOSAS, "spaceType"))
    type && type.to_s.downcase == "void"
  end

  def self.void_id_for(uid)
    suffix = uid.to_s.sub(/^space_/, "")
    "void_#{suffix}"
  end

  def self.build_edge(record, interface_node, height_in, graph, strict)
    faces = record[:faces]
    fail_model(:empty_edge, "edge element has no wall faces", uid: record[:uid]) if faces.empty? && strict
    return nil if faces.empty?
    points = edge_points(faces.first)
    fail_model(:invalid_edge_geometry, "wall face cannot provide a boundary edge", uid: record[:uid]) if points.nil? && strict
    return nil if points.nil?
    edge = MoosasEdge.new(points, height_in, false)
    edge.walls = faces
    edge.glazings = faces.map { |face| face.glazings }.flatten.uniq
    edge.is_internal_edge = internal_edge?(graph, interface_node, record)
    edge.normal = faces.first.normal.to_a if faces.first.normal.respond_to?(:to_a)
    edge.set_len(edge.get_length)
    edge
  end

  def self.edge_points(moosas_face)
    face = moosas_face.face
    return nil if face.nil? || face.vertices.length < 2
    points = face.vertices.map { |vertex| moosas_face.transformation * vertex.position }
    min_z = points.map(&:z).min
    bottom = points.select { |point| (point.z - min_z).abs <= 0.01 }
    bottom = points if bottom.length < 2
    pair = bottom.combination(2).max_by do |a, b|
      ((a.x - b.x) ** 2 + (a.y - b.y) ** 2)
    end
    pair
  end

  def self.internal_edge?(graph, interface_node, record)
    surface = first_object(graph, interface_node, uri(PGD, "surfaceType"))
    return true if ["InteriorWall", "InteriorPartition", "InteriorEdge"].include?(local_name(surface))
    condition = first_object(graph, record[:node], uri(PGD, "hasOutsideBoundaryCondition"))
    condition && condition.to_s == "Indoors"
  end

  def self.assign_semantic_materials(model, spaces)
    physical_spaces = spaces.reject { |space| space.respond_to?(:is_void?) && space.is_void? }
    minimum_floor_height = physical_spaces.map { |space| space.floor.map { |face| face.height }.min }.compact.min || 0
    spaces.each do |space|
      is_void = space.respond_to?(:is_void?) && space.is_void?
      unless is_void
        space.floor.each do |face|
          face.type = face.height <= minimum_floor_height + 1.0 ? MoosasConstant::ENTITY_GROUND_FLOOR : MoosasConstant::ENTITY_FLOOR
        end
        space.ceils.each { |face| face.type = MoosasConstant::ENTITY_ROOF }
      end
      space.bounds.each do |edge|
        edge.walls.each do |face|
          face.type = edge.is_internal_edge ? MoosasConstant::ENTITY_INTERNAL_WALL : MoosasConstant::ENTITY_WALL
        end
        edge.glazings.each do |face|
          face.type = edge.is_internal_edge ? MoosasConstant::ENTITY_INTERNAL_GLAZING : MoosasConstant::ENTITY_GLAZING
        end
      end
    end
    model.get_all_face.each do |face|
      face.assign_material($rad_lib) if face.face && face.face.material
    end
  end

  def self.apply_rdf_element_types(records)
    records.each_value do |record|
      type_name = record[:type_name].to_s
      type = case type_name
             when "AirWall"
               MoosasConstant::ENTITY_AIRWALL
             when "AirSkylight", "AirWindow"
               MoosasConstant::ENTITY_IGNORE
             else
               nil
             end
      next if type.nil?
      record[:faces].each { |face| face.type = type }
    end
  end

  # Any transformed geometry which is not consumed by a space interface is
  # an intentional surrounding/shading element.  Keep it in the model so
  # type visualization and UID inspection cover the complete .geo output.
  def self.attach_unbound_shading(model, geometries)
    recognized_ids = model.get_all_face.map { |face| face.id.to_s }
    Array(geometries).each do |face|
      next if face.nil? || recognized_ids.include?(face.id.to_s)
      face.type = MoosasConstant::ENTITY_SURROUNDING
      model.shading << face unless model.shading.include?(face)
      face.assign_material($rad_lib) if face.respond_to?(:assign_material)
    end
  end

  def self.space_height_m(graph, node)
    area = numeric(first_object(graph, node, uri(PGD, "hasFloorArea_m2")), 0.0)
    volume = numeric(first_object(graph, node, uri(PGD, "hasVolume_m3")), 0.0)
    return volume / area if area > 0.0 && volume > 0.0
    3.0
  end

  def self.element_nodes(graph)
    subjects(graph, uri(RDF_NS, "type"), uri(BOT, "Element"))
  end

  def self.objects(graph, subject, predicate)
    graph_index(graph)[:spo].fetch(subject, {}).fetch(predicate, [])
  end

  def self.subjects(graph, predicate, object)
    graph_index(graph)[:pos].fetch(predicate, {}).fetch(object, [])
  end

  def self.graph_index(graph)
    cached = graph.instance_variable_get(:@moosas_graph_index)
    return cached unless cached.nil?
    spo = Hash.new { |hash, subject| hash[subject] = Hash.new { |predicates, predicate| predicates[predicate] = [] } }
    pos = Hash.new { |hash, predicate| hash[predicate] = Hash.new { |objects, object| objects[object] = [] } }
    graph.each_statement do |statement|
      spo[statement.subject][statement.predicate] << statement.object
      pos[statement.predicate][statement.object] << statement.subject
    end
    spo.each_value { |predicates| predicates.each_value(&:uniq!) }
    pos.each_value { |objects| objects.each_value(&:uniq!) }
    cached = { :spo => spo, :pos => pos }
    graph.instance_variable_set(:@moosas_graph_index, cached)
    cached
  end

  def self.first_object(graph, subject, predicate)
    objects(graph, subject, predicate).first
  end

  def self.literal(graph, subject, predicate)
    value = first_object(graph, subject, predicate)
    value.nil? ? nil : value.to_s
  end

  def self.uri(namespace, local)
    RDF::URI.new(namespace + local)
  end

  def self.local_name(value)
    return nil if value.nil?
    value.to_s.split(/[\#\/]/).last
  end

  def self.numeric(value, fallback)
    return fallback if value.nil?
    Float(value.to_s)
  rescue
    fallback
  end

  def self.blank?(value)
    value.nil? || value.to_s.empty?
  end

  def self.fail_model(code, message, context = {})
    raise ModelError.new(code, message, context)
  end
end
