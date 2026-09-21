# 模型识别模块
module MMR
  require 'set'
  require 'fileutils'
  require 'matrix'
  require 'json'
  require_relative 'MMRGeoExport'
  Ver = '0.6.3'

  INCH_METER_MULTIPLIER = 0.0254
  INCH_METER_MULTIPLIER_SQR = 0.0254 * 0.0254
  IDENTITY_TRANSFORMATION = Geom::Transformation.new
  MATERIAL_ALPHA_THRESHOLD = 0.99
  @geometries ||= []
  @all_recognized_faces ||= []
  @last_rdf_files ||= []
  @transform_running ||= false
  NJTD = 0.05 / 0.0254 # 法向量判断平移距离

  HIDDEN_STATUS = false

  def self.recognize_floor(remodel = true)
    "" "
    Recognizes floors and constructs spaces from the SketchUp model.

    Function:
      Exports model geometry, runs transformation processing, identifies spaces (including ground floor),
      assigns face types, attaches shading, and updates the model with recognized elements.

    Parameters:
      remodel (bool, optional): Whether to remodel the model (solve duplicates/redundancies). Defaults to true.

    Returns:
      MoosasModel: The constructed model containing recognized spaces, faces, and shading elements.
    " ""
    MoosasModelPage.restore_presentation if defined?(MoosasModelPage)
    begin
      MoosasRender.disable_visualize_entity_type($current_model) if $current_model != nil
    rescue
      0
    end

    model = Sketchup.active_model
    previous_rebuild_groups = self.rebuild_groups(model)
    source_entities = self.recognition_source_entities(model).reject do |entity|
      previous_rebuild_groups.include?(entity)
    end
    old_bounds = Geom::BoundingBox.new
    model.entities.each do |entity|
      next if previous_rebuild_groups.include?(entity)
      old_bounds.add(entity.bounds) if entity.respond_to?(:bounds)
    end
    old_bounds = model.bounds if old_bounds.empty?
    model.start_operation("Extract Floor:", true)
    t2 = Time.new
    begin
      zip_command = self.model_to_text(source_entities: source_entities)
      @geometries = zip_command['geometries']
      p "model export to: #{zip_command['input_file']}"

      unless self.exec_transform(zip_command['input_file'], zip_command['rdf_file'], zip_command['geo_file'], true)
        raise "Failed to run MoosasPy transform. Check: #{MPath::DATA}"
      end

      previous_rebuild_groups.each { |group| group.erase! if group.valid? }
      @rebuild_groups = []
      @geometries = self.geo_to_lib(
        zip_command['geo_file'],
        true,
        :east_of => old_bounds
      )
      p "update geometries"

      MoosasRdf.load!
      rdf_graph = RDF::Graph.new
      zip_command['rdf_file'].each do |rdf_file|
        parsed_graph = MoosasRdf.graph_from_turtle(rdf_file)
        parsed_graph.each_statement { |statement| rdf_graph << statement }
      end
      skipped_ids = Array(@skipped_degenerate_geometry_ids)
      unless skipped_ids.empty?
        has_face = (MoosasRdf::MOOSAS + 'hasFace')
        face_id = RDF::URI.new(MoosasRdf::MOOSAS + 'faceId')
        rdf_graph.to_a.each do |statement|
          next unless statement.predicate.to_s == has_face
          linked_id = rdf_graph.query([statement.object, face_id, nil]).map(&:object).first
          linked_id ||= statement.object
          rdf_graph.delete(statement) if skipped_ids.include?(linked_id.to_s)
        end
        p "Ignored zero-area transformed geometry: #{skipped_ids.join(', ')}"
      end
      $ontologies = rdf_graph
      @last_rdf_files = zip_command['rdf_file'].dup
      mm = MoosasRdf.build_model(
        rdf_graph,
        :geometries => @geometries,
        :entities => model.active_entities,
        :strict => true
      )

      @spaces = mm.spaces
      p "Space Number=#{@spaces.size}"

      all_id = mm.get_all_face.map { |face| face.id }
      shading = @geometries.reject { |face| all_id.include?(face.id) }
      shading.each { |moface| attach_shading(mm, moface) }

      $current_model = mm
      $model_updated_number += 1
      MoosasUtils.retrive_setting_data
      MoosasUtils.backup_setting_data
      model.commit_operation

      t3 = Time.new
      p "识别用时： #{t3 - t2}s"
      model_data = mm.pack_data
      MoosasWebDialog.send("update_model_data", model_data)
      @all_recognized_faces = mm.get_all_face
      @all_recognized_faces.each do |mf|
        MoosasRender.update_define_materials(mf.face, mf.type) if mf.face
      end
      MoosasAnalysis.register_recognition(model, zip_command['rdf_file']) if defined?(MoosasAnalysis)
      return mm
    rescue Exception => e
      begin
        model.abort_operation
      rescue
        0
      end
      MoosasUtils.rescue_log(e) if defined?(MoosasUtils)
      raise
    end
  end

  def self.transform_running?
    @transform_running == true
  end

  def self.recognition_source_entities(model)
    selection = model.selection
    # A non-empty selection is an explicit scope, even if it contains nearly
    # every root entity. Only an empty selection means the whole scene.
    selection.empty? ? model.entities : selection
  end

  # Find the top-level groups that contain the current reconstructed faces.
  # This also discovers rebuild groups created before the persistent attribute
  # was introduced, allowing the next Remodel to replace them cleanly.
  def self.rebuild_groups(model = Sketchup.active_model)
    groups = Array(@rebuild_groups).select { |group| group && group.valid? }
    groups.concat(model.entities.grep(Sketchup::Group).select do |group|
      group.get_attribute('MoosasMMR', 'rebuilt_geometry', false)
    end)

    # Older Remodel output has no marker. Its root has one child group per
    # reconstructed face, with no other direct entities; source model groups
    # do not use this generated one-face-per-child layout.
    legacy_groups = model.entities.grep(Sketchup::Group).select do |group|
      children = group.entities.grep(Sketchup::Group)
      !children.empty? && children.length == group.entities.length &&
        children.all? { |child|
          child.entities.grep(Sketchup::Face).length == 1 &&
            child.entities.grep(Sketchup::Group).empty?
        }
    end
    groups.concat(legacy_groups)

    Array(@geometries).each do |geometry|
      face = geometry.respond_to?(:face) ? geometry.face : nil
      next unless face && face.valid?
      current = face
      root = nil
      loop do
        container = current.parent
        owner = container.respond_to?(:parent) ? container.parent : nil
        break unless owner.is_a?(Sketchup::Group)
        root = owner
        current = owner
      end
      groups << root if root && root.parent == model
    end
    groups.uniq.select { |group| group.valid? && group.parent == model }
  end

  def self.recognize_floor_async(remodel = true, main_analysis: false, workspace: nil, &on_complete)
    return false if defined?(MoosasModelPage) && MoosasModelPage.saving?
    @recognition_error = nil
    return false if !main_analysis && defined?(MoosasAnalysis) && MoosasAnalysis.main_analysis_running?
    return false if self.transform_running?
    return false if defined?(MoosasDaylight) && MoosasDaylight.running?

    MoosasModelPage.restore_presentation if defined?(MoosasModelPage)

    model = Sketchup.active_model
    previous_rebuild_groups = self.rebuild_groups(model)
    source_entities = self.recognition_source_entities(model).reject do |entity|
      previous_rebuild_groups.include?(entity)
    end
    old_bounds = Geom::BoundingBox.new
    model.entities.each do |entity|
      next if previous_rebuild_groups.include?(entity)
      old_bounds.add(entity.bounds) if entity.respond_to?(:bounds)
    end
    old_bounds = model.bounds if old_bounds.empty?

    begin
      MoosasRender.disable_visualize_entity_type($current_model) if $current_model != nil
    rescue
      0
    end

    zip_command = self.model_to_text(false, source_entities: source_entities)
    require 'tmpdir'
    jobs = File.join(MPath::DATA, 'jobs')
    FileUtils.mkdir_p(jobs)
    workspace ||= Dir.mktmpdir('recognition-', jobs)
    FileUtils.mkdir_p(workspace)
    # Each recognition owns its exact inputs and outputs. Existing shared RDF
    # files must never make an unsuccessful/new transform look successful.
    %w[input_file rdf_file geo_file].each do |key|
      zip_command[key] = zip_command[key].map do |source|
        target = File.join(workspace, File.basename(source))
        FileUtils.cp(source, target) if key == 'input_file'
        target
      end
    end
    exported_signature = MoosasAnalysis.geometry_signature(model) if defined?(MoosasAnalysis)
    exported_revision = MoosasAnalysis.geometry_revision(model) if defined?(MoosasAnalysis)
    @transform_running = true
    started = self.exec_transform_async(zip_command['input_file'], zip_command['rdf_file'], zip_command['geo_file'], workspace: workspace) do |success|
      operation_started = false
      begin
        unless success
          raise "Failed to run MoosasPy transform. Check: #{MPath::DATA}"
        end
        raise "Active SketchUp model changed during recognition" unless Sketchup.active_model == model
        if exported_signature && exported_signature != MoosasAnalysis.geometry_signature(model)
          raise 'Geometry changed during recognition; please retry'
        end
        if exported_revision && exported_revision != MoosasAnalysis.geometry_revision(model)
          raise 'Geometry revision changed during recognition; please retry'
        end
        model.start_operation("Recognize transformed model:", true)
        operation_started = true
        self.complete_recognize_floor(zip_command, old_bounds, previous_rebuild_groups)
        recognized = true
      rescue Exception => e
        @recognition_error = "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
        begin
          model.abort_operation if operation_started
        rescue
          0
        end
        MoosasUtils.log_error(e) if defined?(MoosasUtils)
        p e.full_message if e.respond_to?(:full_message)
        recognized = false
      ensure
        @transform_running = false
      end
      on_complete.call(recognized) if on_complete
    end

    unless started
      @transform_running = false
      return false
    end
    true
  rescue Exception => e
    @transform_running = false
    MoosasUtils.rescue_log(e) if defined?(MoosasUtils)
    raise
  end

  def self.geometries
    @geometries
  end

  def self.rdf_files
    return @last_rdf_files.select { |path| File.file?(path) } unless @last_rdf_files.empty?

    Dir.glob(File.join(MPath::DATA, "geometry", "selection*.ttl")).select do |path|
      File.basename(path).match?(/\Aselection\d+\.ttl\z/)
    end.sort
  end

  def self.update_model_async(&on_complete)
    return false if self.transform_running?
    return false if defined?(MoosasDaylight) && MoosasDaylight.running?

    needs_rebuild = $current_model == nil || @all_recognized_faces.length != self.all_recognized_faces.length
    if needs_rebuild
      self.recognize_floor_async(true, &on_complete)
    else
      on_complete.call(true) if on_complete
      true
    end
  end

  def self.all_recognized_faces
    "" "
    Retrieves all non-deleted recognized faces.

    Function:
      Filters the stored recognized faces to exclude those that have been deleted from the model.

    Parameters:
      None

    Returns:
      Array[MoosasFace]: List of non-deleted MoosasFace objects.
    " ""
    moosas_faces = []
    @all_recognized_faces.each do |mf|
      unless mf.face.deleted?
        moosas_faces.push(mf)
      end
    end
    return moosas_faces
  end

  def self.attach_shading(model, shdingface)
    "" "
    Attaches shading properties to a face and adds it to the model's shading list.

    Function:
      Sets the face type to surrounding shading, adds it to the model's shading collection,
      and assigns the appropriate material.

    Parameters:
      model (MoosasModel): The model to which the shading face is added.
      shdingface (MoosasFace): The face to be marked as shading.

    Returns:
      None
    " ""
    begin
      shdingface.type = MoosasConstant::ENTITY_SURROUNDING
      model.shading.push(shdingface)
      shdingface.assign_material($rad_lib)
    rescue
    end
  end

  def self.update_model(&on_complete)
    "" "
    Updates the model if changes in recognized faces are detected.

    Function:
      Checks if the current model exists and if the number of recognized faces has changed;
      triggers re-recognition (remodel) if updates are needed.

    Parameters:
      None

    Returns:
      None
    " ""
    self.update_model_async(&on_complete)
  end

  def self.is_glazing(face)
    "" "
    Determines if a face is glazing based on material transparency.

    Function:
      Checks if the face has a material with alpha value below the threshold (semi-transparent).

    Parameters:
      face (Sketchup::Face): The face to check.

    Returns:
      bool: True if the face is glazing, False otherwise.
    " ""
    if face.material && face.material.alpha < MoosasConstant::MATERIAL_ALPHA_THRESHOLD
      return true
    else
      return false
    end
  end

  def self.is_air_wall(face)
    "" "
    Returns true for faces whose assigned material is effectively transparent.

    SketchUp's material alpha is the opacity (1.0 is opaque).  Such faces are
    imported as category 2 so that MoosasPy treats them as AirWall geometry,
    instead of as ordinary glazing or an opaque wall.
    "" "
    materials = [face.material, face.back_material].compact
    !materials.empty? && materials.any? { |material| material.alpha.to_f < 0.10 }
  end

  def self.get_category(face)
    "" "
    Retrieves the category code of a face.

    Function:
      Maps the face's defined material type (or glazing status) to a standardized category code.

    Parameters:
      face (Sketchup::Face): The face to categorize.

    Returns:
      Integer: Category code (e.g., 3 for wall, 5 for glazing, 0 for default).
    " ""

    mat_translate = {
      MoosasConstant::ENTITY_WALL => 3,
      MoosasConstant::ENTITY_INTERNAL_WALL => 3,
      MoosasConstant::ENTITY_GLAZING => 5,
      MoosasConstant::ENTITY_INTERNAL_GLAZING => 5,
      MoosasConstant::ENTITY_SKY_GLAZING => 6,
      MoosasConstant::ENTITY_ROOF => 4,
      MoosasConstant::ENTITY_FLOOR => 4,
      MoosasConstant::ENTITY_GROUND_FLOOR => 4,
      MoosasConstant::ENTITY_SHADING => -1,
      MoosasConstant::ENTITY_PARTY_WALL => 3,
      MoosasConstant::ENTITY_DOOR => 5,
      MoosasConstant::ENTITY_AIRWALL => 2,
      MoosasConstant::ENTITY_SURROUNDING => -1,
      MoosasConstant::ENTITY_IGNORE => -2
    }
    # A face below 10% opacity is an AirWall regardless of the material tag.
    # This check must precede the generic glazing rule (< 99% opacity).
    return 2 if self.is_air_wall(face)

    if $define_materials.has_key?(face.persistent_id)
      return mat_translate[$define_materials[face.persistent_id]]
    else
      if self.is_glazing(face)
        return 1
      else
        return 0
      end
    end

  end

  # Keep triangulation for compatibility with the surface-analysis exporter.
  # RAD also supports concave polygon records and explicit hole rings.
  def self.geo_export_face(face, transformation, source_id, force_triangles: false)
    to_metres = proc { |point| (transformation * point).to_a.map { |v| v * INCH_METER_MULTIPLIER } }
    loops = ([face.outer_loop] + face.loops.reject { |loop| loop == face.outer_loop }).map do |loop|
      {keys: loop.vertices.map(&:persistent_id), points: loop.vertices.map { |v| to_metres.call(v.position) }}
    end
    mesh_triangles = proc do
      mesh = face.mesh(0)
      mesh.polygons.map do |polygon|
        # Mesh indices can be negative to flag hidden edges.
        points = polygon.map { |index| mesh.point_at(index.abs) }
        raise "Non-triangular SketchUp mesh for #{source_id}" unless points.length == 3
        cross = (points[1] - points[0]).cross(points[2] - points[0])
        points.reverse! if cross.dot(face.normal) < 0
        points.map { |point| to_metres.call(point) }
      end
    end
    result = if force_triangles
               rejected = []
               world_normal = face.normal.transform(transformation)
               triangles = mesh_triangles.call.each_with_index.select do |triangle, index|
                 rounded_triangle = MMRGeoExport.rounded(triangle)
                 basis = MMRGeoExport.frame(rounded_triangle)
                 valid = basis && MMRGeoExport.simple?(MMRGeoExport.project(rounded_triangle, basis)) &&
                         MMRGeoExport.rad_projected_triangle?(triangle, world_normal)
                 rejected << {source_id: source_id, triangle: index + 1, reason: 'degenerate_after_rounding'} unless valid
                 valid
               end.map(&:first)
               {mode: 'triangles', rejected: rejected, records: triangles.each_with_index.map { |triangle, index|
                 {id: "#{source_id}__tri_#{format('%04d', index + 1)}", outer: triangle, holes: []}
               }}
             else
               MMRGeoExport.normalize(source_id, loops, &mesh_triangles)
             end
    result[:source_id] = source_id
    result[:persistent_id] = face.persistent_id
    result
  end

  def self.model_to_text(start_operation = true, output_dir: nil, source_entities: nil)
    "" "
    Exports model geometry to text-based .geo files.

    Function:
      Traverses selected faces/groups, applies world transformations, converts coordinates to meters,
      and writes face data (vertices, normals, categories) to .geo files.

    Parameters:
      output_dir: Optional isolated output directory; defaults to data/geometry.
      source_entities: Optional source collection; defaults to the live selection.

    Returns:
    Hash: Contains geometries (MoosasFace list), input_file (geo paths),
      geo_file (processed geo paths), and rdf_file (ontology paths).
    " ""
    input_file, rdf_file, geo_file = [], [], []
    model = Sketchup.active_model
    selection = source_entities || model.selection
    output_dir ||= File.join(MPath::DATA, 'geometry')
    # Geometry exports are generated at runtime and the repository may not
    # contain the output directory in a fresh checkout.
    FileUtils.mkdir_p(output_dir)
    model.start_operation("Export model to geo", true) if start_operation
    # Keep the selected instances, not only their Entities collections. The
    # instance chain carries each group's local-to-world transformation and
    # traverse_faces applies it while exporting that group independently.
    group_entities = selection.select do |entity|
      entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
    end
    set_group, set_select = Set.new(), Set.new()
    self.traverse_faces(group_entities) { |e, path| set_group.add(e) }
    self.traverse_faces(selection) { |e, path| set_select.add(e) }
    set_remain = set_select.difference(set_group)
    if set_remain.size != 0
      group_entities.push(set_remain.to_a)
    end
    raise "Select model faces or groups before remodeling" if group_entities.empty?
    p "Selection include groups: " + group_entities.length.to_s
    geometries = []
    total_face_number = 0
    id = -1
    for i in 0..group_entities.length - 1
      geometries[i] = []
      model_text = ""
      export_repairs = []
      self.traverse_faces(group_entities[i]) do |e, path|
        if user_visible?(e) && path.all? { |p| user_visible? p }
          transformation = path.inject(IDENTITY_TRANSFORMATION) { |t, f| t * f.transformation }
          id += 1
          cat = self.get_category(e)
          normal = e.normal
          exported = self.geo_export_face(e, transformation, "#{i}_#{id}")
          exported[:records].each do |record|
            model_text += MMRGeoExport.serialize(record, cat, normal)
            geometries[i].push(MoosasFace.new(e, transformation, e.area, normal, record[:id]))
          end
          unless exported[:mode] == 'unchanged'
            repair = exported.reject { |key, _| key == :records }
            repair[:output_ids] = exported[:records].map { |record| record[:id] }
            export_repairs << repair
            p "GEO export #{repair[:source_id]} (face #{repair[:persistent_id]}): #{repair[:mode]}"
          end
        end
      end
      input_file.push(File.join(output_dir, "selection#{i}.geo"))
      rdf_file.push(File.join(output_dir, "selection#{i}.ttl"))
      geo_file.push(File.join(output_dir, "selection#{i}_out.geo"))
      File.write(input_file.last, model_text)
      File.write(File.join(output_dir, "selection#{i}_export_repairs.json"), JSON.pretty_generate(export_repairs))
    end
    return { 'geometries' => geometries, 'input_file' => input_file, 'rdf_file' => rdf_file, 'geo_file' => geo_file }
  end

  def self.geo_to_lib(geo_file, reform = true, placement = nil)
    "" "
    Imports processed .geo files and reconstructs faces in the SketchUp model.

    Function:
      Reads .geo data, projects vertices to coplanar positions, creates faces with materials,
      and updates the geometries list with new MoosasFace objects.

    Parameters:
      geo_file (Array[String]): Paths to processed .geo files.
      reform (bool, optional): Whether to reconstruct faces. Defaults to true.

    Returns:
      Array[MoosasFace]: Updated list of reconstructed MoosasFace objects.
    " ""
    @skipped_degenerate_geometry_ids = [] if reform
    # A remodel is placed beside the source model, so it must keep the
    # source model's world Z coordinates. The historical depth-based offset
    # made the rebuilt model appear in the air.
    offset = placement ? 0.0 : Sketchup.active_model.bounds.depth * 1.1

    # Every selection*.geo is an independent recognition/transformation job,
    # but its vertices are already in the same world-coordinate frame. Use
    # one shared placement delta for all files; calculating a delta per file
    # would align every group to the same min-X and stack them on top of one
    # another.
    translation_x = 0.0
    if reform && placement && placement[:east_of]
      global_source_min_x = nil
      geo_file.each do |path|
        File.foreach(path) do |line|
          next unless line.start_with?("fv,")
          x = line.strip.split(",")[1].to_f / 0.0254
          global_source_min_x = x if global_source_min_x.nil? || x < global_source_min_x
        end
      end
      if global_source_min_x
        translation_x = placement[:east_of].max.x - global_source_min_x
      end
    end

    for file_i in 0..geo_file.length - 1
      valid_id, geo_pts, cats, geo_normals = [], [], [], []
      gfile = geo_file[file_i]
      File.open(gfile, "r") do |f|
        geostr = []
        while line = f.gets
          if line[0] == ";"
            cats.push(geostr[0][1])
            valid_id.push(geostr[0][2])
            pts = []
            for stri in 0..geostr.length - 1
              if geostr[stri][0] == "fv"
                pts.push([geostr[stri][1].to_f() / 0.0254, geostr[stri][2].to_f() / 0.0254, geostr[stri][3].to_f() / 0.0254])
              end
              if geostr[stri][0] == "fn"
                geo_normals.push([geostr[stri][1].to_f(), geostr[stri][2].to_f(), geostr[stri][3].to_f()])
              end
            end
            geo_pts.push(pts)
            geostr = []
          else
            line = line.strip().split(",")
            geostr.push(line)
          end
        end
      end

      valid_id.each { |geo_id|
        if geo_id[0] == "n"
          reform = true
        end }

      if reform
        model = Sketchup.active_model
        @rebuild_group = model.entities.add_group
        @rebuild_group.set_attribute('MoosasMMR', 'rebuilt_geometry', true)
        @rebuild_groups ||= []
        @rebuild_groups << @rebuild_group
        materials = model.materials
        materialWll = materials.add('wall')
        materialWll.color = 'White'
        materialWll.alpha = 1.0
        materialGls = materials.add('glass')
        materialGls.color = 'Blue'
        materialGls.alpha = 0.5
        materialAir = materials.add('air')
        materialAir.color = 'Red'
        materialAir.alpha = 0.09
        # group = model.entities.add_group
        new_geometries = []

      for geoI in 0..valid_id.length - 1
        gid = valid_id[geoI]
        pts = geo_pts[geoI]
        pts = pts.map { |point| [point[0] + translation_x, point[1], point[2]] }
        pts = self.simplified(pts, offset)
        if pts.length < 3
          next
        end
        unless MMRGeoExport.frame(pts)
          @skipped_degenerate_geometry_ids ||= []
          @skipped_degenerate_geometry_ids << gid.to_s
          next
        end
        ent = @rebuild_group.entities.add_group.entities
          if geo_normals[geoI][2] == 0 or geo_normals[geoI][0] + geo_normals[geoI][1] == 0
            e = ent.add_face(pts)
          else
            # e = self.add_2d_face(ent,pts,geo_normals[geoI])
            e = self.draw_coplanar_face(ent, pts, geo_normals[geoI])

          end

          # The source .geo uses 0/1/2, while transformed output may use
          # semantic Moosas categories (3=wall, 5=glazing, 6=skylight).
          # Normalize both representations for the diagnostic rebuild view.
          geo_category = cats[geoI].to_i
          if geo_category == 0 || geo_category == 3 || geo_category == 4 || geo_category == -1
            e.material = materialWll
            e.back_material = materialWll
          end
          if geo_category == 1 || geo_category == 5 || geo_category == 6
            e.material = materialGls
            e.back_material = materialGls
          end
          if geo_category == 2
            e.material = materialAir
            e.back_material = materialAir
          end
          transformation = self.get_world_transformation(e)
          new_geometries.push(MoosasFace.new(e, transformation, e.area, e.normal, gid))
        end
        @geometries[file_i] = new_geometries
      end

    end
    new_geometries = []
    @geometries.each { |geoseries| geoseries.each { |geo| new_geometries.push(geo) } }
    @geometries = new_geometries
    return @geometries
  end

  def self.exec_transform(input_file, rdf_file, geo_file, remodel = true)
    "" "
    Executes Python transformation script to process .geo files.

    Function:
      Generates Python code to run MoosasPy.transform, handles model processing (duplicate removal, etc.),
      and executes the script with appropriate Python interpreter.

    Parameters:
      input_file (Array[String]): Paths to input .geo files.
      rdf_file (Array[String]): Paths to output .ttl files.
      geo_file (Array[String]): Paths to processed .geo files.
      remodel (bool, optional): Whether to enable advanced processing. Defaults to false.

    Returns:
      bool: True if the Python script executed successfully, False otherwise.
    " ""
    request = {'input_file'=>input_file, 'rdf_file'=>rdf_file, 'geo_file'=>geo_file, 'settings_path'=>MoosasUtils.settings_path}
    code = ['from skp.scripts.transform_job import execute', "execute(#{request.to_json})"]
    MoosasUtils.exec_python("transform.py", code, true)
  end

  def self.exec_transform_async(input_file, rdf_file, geo_file, workspace: nil, &on_complete)
    parent = File.join(MPath::DATA, 'jobs')
    FileUtils.mkdir_p(parent)
    workspace ||= Dir.mktmpdir('transform-', parent)
    FileUtils.mkdir_p(workspace)
    request = {'input_file'=>input_file, 'rdf_file'=>rdf_file, 'geo_file'=>geo_file, 'settings_path'=>MoosasUtils.settings_path}
    request_path = File.join(workspace, 'request.json')
    File.write(request_path, JSON.generate(request), encoding: 'UTF-8')
    code = ['from skp.scripts.transform_job import execute', "execute(#{request_path.to_json})"]
    MoosasUtils.exec_python_async("transform.py", code, workspace: workspace, console: true, &on_complete)
  end

  def self.complete_recognize_floor(zip_command, old_bounds, previous_rebuild_groups = [])
    model = Sketchup.active_model
    @geometries = zip_command['geometries']
    p "model export to: #{zip_command['input_file']}"
    previous_rebuild_groups.each { |group| group.erase! if group.valid? }
    @rebuild_groups = []
    @geometries = self.geo_to_lib(
      zip_command['geo_file'],
      true,
      :east_of => old_bounds
    )
    p "update geometries"

    MoosasRdf.load!
    rdf_graph = RDF::Graph.new
    zip_command['rdf_file'].each do |rdf_file|
      parsed_graph = MoosasRdf.graph_from_turtle(rdf_file)
      parsed_graph.each_statement { |statement| rdf_graph << statement }
    end
    skipped_ids = Array(@skipped_degenerate_geometry_ids)
    unless skipped_ids.empty?
      has_face = MoosasRdf::MOOSAS + 'hasFace'
      face_id = RDF::URI.new(MoosasRdf::MOOSAS + 'faceId')
      rdf_graph.to_a.each do |statement|
        next unless statement.predicate.to_s == has_face
        linked_id = rdf_graph.query([statement.object, face_id, nil]).map(&:object).first
        linked_id ||= statement.object
        rdf_graph.delete(statement) if skipped_ids.include?(linked_id.to_s)
      end
      p "Ignored zero-area transformed geometry: #{skipped_ids.join(', ')}"
    end
    $ontologies = rdf_graph
    @last_rdf_files = zip_command['rdf_file'].dup
    mm = MoosasRdf.build_model(
      rdf_graph,
      :geometries => @geometries,
      :entities => model.active_entities,
      :strict => true
    )

    @spaces = mm.spaces
    p "Space Number=#{@spaces.size}"
    all_id = mm.get_all_face.map { |face| face.id }
    shading = @geometries.reject { |face| all_id.include?(face.id) }
    shading.each { |moface| attach_shading(mm, moface) }

    $current_model = mm
    $model_updated_number += 1
    MoosasUtils.retrive_setting_data
    MoosasUtils.backup_setting_data
    model.commit_operation

    model_data = mm.pack_data
    MoosasWebDialog.send("update_model_data", model_data)
    @all_recognized_faces = mm.get_all_face
    @all_recognized_faces.each do |mf|
      MoosasRender.update_define_materials(mf.face, mf.type) if mf.face
    end
    MoosasAnalysis.register_recognition(model, zip_command['rdf_file']) if defined?(MoosasAnalysis)
    mm
  end

  # XML model reconstruction is intentionally disabled. RDF is the only
  # runtime semantic source for a rebuilt MoosasModel.
  if false
  def self.read_xml(files)
    "" "
    Reads .xml files and constructs space objects from processed geometry data.

    Function:
      Parses wall, face, glazing, and space data from .xml, constructs MoosasEdge and MoosasSpace objects,
      and maps geometry to spaces.

    Parameters:
      files (Array[String]): Paths to .xml files containing space data.

    Returns:
      Array[MoosasSpace]: List of constructed space objects, or nil if files are missing.
    " ""
    spaces = []
    for xml_file in files
      if !FileTest::exists?(xml_file)
        p "File not exist. check:"
        p xml_file
        return nil
      end

      # initialize
      walls = {}
      faces = {}
      glazings = {}
      spc_xml = File.new(xml_file)
      spc_doc = Document.new(spc_xml)
      root = spc_doc.root
      model = Sketchup.active_model
      entities = model.active_entities

      root.each_element('wall') do |w_element|
        face_uid = w_element.get_elements('Uid')[0].text
        walls[face_uid] = w_element
      end
      root.each_element('face') do |f_element|
        face_uid = f_element.get_elements('Uid')[0].text
        faces[face_uid] = f_element
      end
      root.each_element('glazing') do |g_element|
        face_uid = g_element.get_elements('Uid')[0].text
        glazings[face_uid] = g_element
      end
      root.each_element('skylight') do |s_element|
        face_uid = s_element.get_elements('Uid')[0].text
        glazings[face_uid] = s_element
      end

      root.each_element('space') do |spc|
        _floor, _ceiling, _edge, _bounds = [], [], [], []
        topology = spc.get_elements('topology')[0]

        topology.each_element('floor') { |fl_element|
          fl_element.each_element('face') { |fid|
            f = faces[fid.text]
            floorface = self.construct_face(f, glazings)
            if floorface == nil
              next
            end
            _floor += floorface
          }
        }

        topology.each_element('ceiling') { |ci_element|
          ci_element.each_element('face') { |fid|
            f = faces[fid.text]
            ceilface = self.construct_face(f, glazings)
            if ceilface == nil
              next
            end
            _ceiling += ceilface
          }
        }

        spc.each_element('boundary') { |bd_element|
          pts = []
          bd_element.each_element('pt') { |pt|
            pts.push(pt.text.split(" ").map { |dim| dim.to_f })
          }
          for i in 0..pts.length - 2
            _bounds.push([pts[i], pts[i + 1]])
          end
          _bounds.push([pts[-1], pts[0]])
        }
        _height = spc.get_elements('height')[0].text.to_f()
        topology.each_element('edge') { |ed_element|
          _walls = ed_element.get_elements('wall').map { |wl| walls[wl.get_elements('Uid')[0].text] }
          norms = ed_element.get_elements('wall').map { |wl|
            wl.get_elements('normal')[0].text.split(" ").map { |num|
              num.to_f()
            }
          }

          for i in 0.._walls.length - 1
            if _walls[i].get_elements('external')[0].text == "True"
              internal = false
            else
              internal = true
            end
            _normal = norms[i]

            _length = _walls[i].get_elements('length')[0].text.to_f()
            distance = (_bounds[i][0][0] - _bounds[i][1][0]) * (_bounds[i][0][0] - _bounds[i][1][0]) +
              (_bounds[i][0][1] - _bounds[i][1][1]) * (_bounds[i][0][1] - _bounds[i][1][1])
            distance = Math.sqrt(distance)
            _wall = MoosasEdge.new(_bounds[i], _height, require_infer = false)
            _wall.set_len(_length)

            e = construct_face(_walls[i], glazings)
            if e == nil
              next
            end
            _wall.walls = e
            _wall.glazings = e[0].glazings

            g_area = 0.0
            for g in _wall.glazings
              g_area += g.face.area * MoosasConstant::INCH_METER_MULTIPLIER_SQR
            end
            e_area = 0.0
            for e in _wall.walls
              e_area += e.face.area * MoosasConstant::INCH_METER_MULTIPLIER_SQR
            end
            begin
              _wwr = g_area / (distance * _height)
              _wall.area_m = distance * _height
            rescue
              _wwr = g_area / e_area
              _wall.area_m = e_area
            end
            # p "wwr:#{_wwr}",g_area,distance,_height
            _wall.wwr = _wwr
            # _wall.area_m = (g_area+e_area)*MoosasConstant::INCH_METER_MULTIPLIER_SQR
            _wall.is_internal_edge = internal
            for g in _wall.glazings
              g.normal = Geom::Vector3d.new(_normal)
            end
            _wall.normal = Geom::Vector3d.new(_normal)
            _wall.normal.length = 1
            _edge.push(_wall)
          end

        }
        spaces.push(self.construct_space(spc, _floor, _ceiling, _edge))
      end

      # shading_elements=root.get_elements('shading')[0].get_elements('face')
      # shading_elements.each{|sd_element|
      #     moface=self.find_geometry(sd_element.text.to_i())
      #     glazing=sd_element.attribute('glazingId').value()
      #     self.find_geometry(glazing).shading.push(moface)
      # }

    end
    return spaces
  end

  def self.find_geometry(idd)
    "" "
    Finds a MoosasFace by its ID.

    Function:
      Searches the stored geometries list to find a MoosasFace matching the given ID.

    Parameters:
      idd (String/Integer): ID of the MoosasFace to find.

    Returns:
      MoosasFace or nil: The matching MoosasFace if found, nil otherwise.
    " ""
    rf = nil
    @geometries.each do |moface|
      if moface.id == idd
        return moface
      end
    end
    return rf
  end

  def self.construct_by_boundary(_element, entities, offset_height = 0)
    "" "
    Constructs a face from boundary points in the model.

    Function:
      Reads boundary points from an XML element, adjusts z-coordinate with offset, creates a face in a group,
      and returns a MoosasFace with world transformation.

    Parameters:
      _element (REXML::Element): XML element containing boundary points.
      entities (Sketchup::Entities): Entities container to create the face in.
      offset_height (Float, optional): Z-axis offset for the face. Defaults to 0.

    Returns:
      MoosasFace: The constructed face with calculated height and transformation.
    " ""
    pts = []
    _element.each_element('pt') { |pt|
      pts.push(pt.text.split(" "))
    }
    for i in 0..pts.length - 1
      pts[i] = [pts[i][0].to_f(), pts[i][1].to_f(), pts[i][2].to_f() + offset_height]
    end
    group = entities.add_group
    entities2 = group.entities
    e = entities2.add_face(pts)
    transformation = self.get_world_transformation(e)
    fl = MoosasFace.new(e, transformation, e.area, e.normal, generate_plane_id())
    fl.calculate_height
    return fl
  end

  def self.construct_face(_element, glazings)
    "" "
    Constructs a MoosasFace from XML element data and glazing mappings.

    Function:
      Retrieves face IDs, glazing IDs, and height from XML, finds corresponding geometries,
      attaches glazing data to the face, and returns the face list.

    Parameters:
      _element (REXML::Element): XML element containing face data.
      glazings (Hash): Hash mapping glazing UIDs to their XML elements.

    Returns:
      Array[MoosasFace] or nil: List of constructed MoosasFace objects, nil if face is not found.
    " ""
    _height = _element.get_elements('height')[0].text.to_f
    _id = _element.get_elements('faceId')[0].text.split(" ")
    _uid = _element.get_elements('Uid')[0].text
    _face = _id.map { |g| self.find_geometry(g) }
    if _face[0] == nil
      p _id
      return nil
    end
    fl_glazing = []
    _glazing = _element.get_elements('glazingId')[0].text
    if _glazing == nil
      fl_glazing = []
    else
      _glazing.split(" ") do |glazingUid|
        gls = glazings[glazingUid]
        gls_ids = gls.get_elements('faceId')[0].text.split(" ")
        gls_ids.each do |g|
          g_moface = self.find_geometry(g)
          g_moface.uid = glazingUid
          fl_glazing.push(g_moface)
        end
      end
    end
    for f in _face
      f.glazings = fl_glazing
      f.height = _height
      f.uid = _uid
    end
    return _face
  end

  def self.construct_space(_element, _floor, _ceil, _bound)
    "" "
    Constructs a MoosasSpace from floor, ceiling, boundary, and XML data.

    Function:
      Initializes a space with floor/ceiling faces, boundary edges, height, and ID;
      marks space as outer/inner based on boundary walls.

    Parameters:
      _element (REXML::Element): XML element containing space metadata (height, ID, etc.).
      _floor (Array[MoosasFace]): List of floor faces for the space.
      _ceil (Array[MoosasFace]): List of ceiling faces for the space.
      _bound (Array[MoosasEdge]): List of boundary edges for the space.

    Returns:
      MoosasSpace or nil: The constructed space object, nil if required components are missing.
    " ""
    if _floor == [] or _ceil == [] or _bound == []
      p "_floorNil" if _floor == []
      p "_ceilNil" if _ceil == []
      p "_boundNil" if _bound == []
      return nil
    end
    _height = _element.get_elements('height')[0].text.to_f() / MoosasConstant::INCH_METER_MULTIPLIER
    space_id = _element.get_elements('id')[0].text
    neighbor = _element.get_elements('neighbor')
    s = MoosasSpace.new(_floor, _height, _ceil, _bound, id = space_id)
    # s.set_id("s_0x"+space_id)
    s.is_outer = false
    # neighbor.each{|nei| s.neighbor[nei.text]=self.find_geometry(nei.attribute('Faceid').value()).id}
    internal_wall = _element.each_element('internal_wall') { |e|
      if e.text != nil
        e.text.split(' ').each { |w|
          s.internal_wall.append(self.find_geometry(w))
        }
      end
    }

    for wall in _bound
      # s.bounds.push(wall)
      if !wall.is_internal_edge
        s.is_outer = true
      end
    end
    # p "Create Space #{space_id} at the Height #{_floor.height*MMR::INCH_METER_MULTIPLIER}m"
    return s
  end
  end

  def self.generate_plane_id()
    "" "
    Generates a unique ID for a plane/face.

    Function:
      Creates a random 8-character alphanumeric code prefixed with p_0x for unique identification.

    Parameters:
      None

    Returns:
      String: Unique plane ID (e.g., p_0xa3f2d4e5).
    " ""

    code = [*'a'..'f', *'0'..'9'].sample(8).join
    # return "p_"+rand(10000).to_s+"_"+Time.now.to_f.to_s
    return "p_0x" + code
  end

  def self.user_visible?(e)
    "" "
    Checks if an entity is visible to the user.

    Function:
      Verifies if the entity itself and its parent layer are both visible in the SketchUp model.

    Parameters:
      e (Sketchup::Entity): The entity to check (face, group, etc.).

    Returns:
      bool: True if the entity is visible, False otherwise.
    " ""
    e.visible? && e.layer.visible?
  end

  def self.traverse_faces(entity, path = [], &func)
    "" "
    Recursively traverses entities to find all faces.

    Function:
      Iterates through groups, components, entities collections, and selections to find faces;
      executes a callback function with each face and its parent path.

    Parameters:
      entity (Sketchup::Entity/Enumerable): Entity to traverse (face, group, entities, etc.).
      path (Array[Sketchup::Group/ComponentInstance], optional): Parent path of the current entity. Defaults to empty array.
      &func (Proc): Callback function to execute for each face (accepts 1 or 2 arguments: face, path).

    Returns:
      None
    " ""
    case entity
    when Sketchup::Face
      func.arity == 1 ? func.call(entity) : func.call(entity, path)
    when Sketchup::Group
      return if entity.attribute_dictionary('grid', false) || entity.get_attribute('MoosasDaylight', 'visualization', false) ||
        entity.get_attribute('MoosasSurfaceAnalysis', 'visualization', false)
      traverse_faces(entity.entities, path + [entity], &func)
    when Sketchup::ComponentInstance
      return if entity.get_attribute('MoosasDaylight', 'visualization', false) ||
        entity.get_attribute('MoosasSurfaceAnalysis', 'visualization', false)
      traverse_faces(entity.definition.entities, path + [entity], &func)
    when Sketchup::Entities, Sketchup::Selection, Enumerable
      entity.each { |e| traverse_faces(e, path, &func) }
    end
  end

  # find the transformation of a existing face
  def self.get_world_transformation(entity)
    "" "
    Calculates the world transformation matrix for an entity.

    Function:
      Traverses the entity's parent hierarchy (groups/components), collects transformation matrices,
      and computes the total transformation from local to world coordinates.

    Parameters:
      entity (Sketchup::Entity): The entity to compute the transformation for (face, edge, etc.).

    Returns:
      Geom::Transformation: Total transformation matrix from local to world coordinates.
    " ""
    # 收集实体所在的层级路径（从实体的直接父到顶层容器）
    path = []
    current = entity.parent

    # 遍历父容器，收集组或组件实例（与traverse_faces的path逻辑对应）
    while current.is_a?(Sketchup::Group) || current.is_a?(Sketchup::ComponentInstance)
      path << current # 路径按“直接父 -> 祖父 -> ... -> 顶层”顺序存储
      current = current.parent
    end

    # 计算总变换矩阵：路径中所有容器的变换依次相乘（从顶层到直接父）
    # 注：path的顺序是“直接父在前、顶层在后”，因此需要reverse后再计算
    return path.reverse.inject(IDENTITY_TRANSFORMATION) { |total, container| total * container.transformation }
  end

  def self.show_space_info(space)
    return unless MoosasRender.debug_face_ids?
    "" "
    Adds text labels to the model showing space and face details.

    Function:
      Creates text entities at face centroids displaying space ID, face ID, area, material, WWR, and radiation data.

    Parameters:
      space (MoosasSpace): The space to display information for.

    Returns:
      None
    " ""
    model = Sketchup.active_model
    entities = model.entities
    space.floor.each { |f|
      t = entities.add_text("#{space.id}_floor\nId:#{f.id}\nArea:#{f.area_m.round(2)}\nMaterial:#{$rad_lib[f.material].category + "_" + $rad_lib[f.material].name}\n", f.centroid)
    }

    space.ceils.each { |f|
      t = entities.add_text("#{space.id}_ceiling\nId:#{f.id}\nArea:#{f.area_m.round(2)}\nMaterial:#{$rad_lib[f.material].category + "_" + $rad_lib[f.material].name}\n", f.centroid)
    }

    for w in space.bounds
      str = "#{space.id}_wall\n"
      position = nil
      for f in w.walls
        # t = entities.add_text("#{space.id}_wall_#{w.wwr}", f.centroid)
        str += "Id:#{f.id}\nArea:#{f.area_m.round(2)}\nMaterial:#{$rad_lib[f.material].category + "_" + $rad_lib[f.material].name}\nWwr:#{w.wwr.round(2)}\n"
        position = f.centroid
        # allentities.add_line(f.centroid,f.centroid+w.normal.to_a())
      end
      for g in w.glazings
        str += "_glazing_Id:#{g.id}\nArea:#{g.area_m.round(2)}\nMaterial:#{$rad_lib[g.material].category + "_" + $rad_lib[g.material].name}\n"
      end
      str += "summer_rad:#{w.settings['summer_rad']}\nwinter_rad:#{w.settings['winter_rad']}\n"
      t = entities.add_text(str, position)
    end
    for w in space.internal_wall
      t = entities.add_text("#{space.id}_internal_wall_\nId:#{w.id}\nArea:%.2f" % w.area_m, w.centroid)
    end
  end

  def self.select_space_walls(i)
    "" "
    Highlights walls of a specific space by hiding other faces.

    Function:
      Hides all faces except those belonging to the specified space, and deletes existing text labels.

    Parameters:
      i (Integer): Index of the target space in the @spaces list.

    Returns:
      String: ID of the selected space.
    " ""
    model = Sketchup.active_model
    entities = model.active_entities
    texts = entities.grep(Sketchup::Text)
    entities.erase_entities(texts)
    model.start_operation("select_space_walls #{i}", true)

    '' '
        j = 0
        while j < @spaces.length
            if i != j
                s = @spaces[j]
                s.walls.each do |w|
                    w.face.hidden = true
                end
                s.ceils.each do |w|
                    w.face.hidden = true
                end
            end
            j += 1
        end
        ' ''

    self.hide_all_face()
    s = @spaces[i]
    mofaces = s.get_all_face
    mofaces.each { |mf| mf.face.hidden = false }
    s.floor.each { |f| p f.area_m }
    # p 'space'
    # p s.area_m
    # show_space_info(s)

    model.commit_operation
    return s.id
  end

  def self.show_all_face
    "" "
    Shows all hidden faces in the model.

    Function:
      Traverses all model entities, unhides all faces, and deletes existing text labels.

    Parameters:
      None

    Returns:
      None
    " ""
    Sketchup.active_model.start_operation("显示所有的面", true)
    model = Sketchup.active_model
    entities = model.active_entities
    texts = entities.grep(Sketchup::Text)
    entities.erase_entities(texts)
    self.traverse_faces(Sketchup.active_model.entities) do |e, path|
      e.hidden = false
    end
    Sketchup.active_model.commit_operation
  end

  def self.hide_all_face
    "" "
    Hides all faces in the model.

    Function:
      Traverses all model entities and hides all faces.

    Parameters:
      None

    Returns:
      None
    " ""
    Sketchup.active_model.start_operation("隐藏所有的面", true)
    self.traverse_faces(Sketchup.active_model.entities) do |e, path|
      e.hidden = true
    end
    Sketchup.active_model.commit_operation
  end

  def self.visualize_factor()
    "" "
    Visualizes factor data for space boundaries.

    Function:
      Creates a group and adds visualization elements for boundary factors (e.g., radiation) of all spaces.

    Parameters:
      None

    Returns:
      None
    " ""
    group = Sketchup.active_model.active_entities.add_group
    entities = group.entities
    $current_model.simulation_spaces.each { |space|
      space.bounds.each { |b|
        entities = b.visualize_factor(entities)
      }
    }
  end

  def self.simplified(pts, offset)
    "" "
    Simplifies a list of vertices by removing duplicate points.

    Function:
      Applies a z-axis offset, removes vertices that form zero-length edges, and converts vectors back to arrays.

    Parameters:
      pts (Array[Array[Float]]): List of vertices (x, y, z) to simplify.
      offset (Float): Z-axis offset to apply to all vertices.

    Returns:
      Array[Array[Float]]: Simplified list of vertices.
    " ""
    pts = pts.map { |pt| Geom::Vector3d.new([pt[0], pt[1], pt[2] + offset]) }
    # pts.unshift(pts[-1])
    # pts.push(pts[0])

    pts_temp = pts
    pts = []
    for i in 0..pts_temp.length - 1
      edge1 = pts_temp[i] - pts_temp[i - 1]
      unless edge1.length == 0
        pts.push(pts_temp[i])
      end
    end
    pts_new = pts
    # pts_new = []
    # for i in 1..pts.length-2
    #     pts_new.push(pts[i])
    #     # edge1 = pts[i]-pts[i-1]
    #     # edge2 = pts[i+1]-pts[i]
    #     # edge1.length = 1
    #     # edge2.length = 1
    #     # dot =edge1.dot(edge2)
    #     # unless dot >= 0.999 or dot <=-0.999
    #     #     pts_new.push(pts[i])
    #     # end
    # end

    pts_new = pts_new.map { |pt| pt.to_a }
    return pts_new
  end

  def self.draw_coplanar_face(entities, pts, normal)
    "" "
    Draws a coplanar face by projecting vertices to a target plane (corrects minor errors).

    Function:
      Normalizes the input normal, calculates the target plane equation, projects all vertices to the plane,
      creates a face, and ensures the face normal matches the input.

    Parameters:
      entities (Sketchup::Entities): Entities container to create the face in.
      pts (Array[Geom::Point3d/Array[Float]]): List of vertices (may have coplanarity errors).
      normal (Geom::Vector3d/Array[Float]): Target normal vector for the coplanar face.

    Returns:
      Sketchup::Face or nil: The created coplanar face, nil if input is invalid.
    " ""
    # 输入验证
    return nil unless entities.is_a?(Sketchup::Entities)
    return nil if pts.size < 3 # 至少需要3个点才能创建面
    return nil if normal.length == 0 # 法向量不能为零向量

    # 规范化法向量（确保方向一致，不影响长度）
    normal = Geom::Vector3d.new(normal).normalize

    # Project relative to a nearby origin to avoid cancellation at large
    # world coordinates. GEO coordinates may be rounded to millimetres.
    origin = Geom::Point3d.new(pts.first)
    reference = normal.parallel?(Geom::Vector3d.new(1, 0, 0)) ?
      Geom::Vector3d.new(0, 1, 0) : Geom::Vector3d.new(1, 0, 0)
    axis_x = normal.cross(reference).normalize
    axis_y = normal.cross(axis_x).normalize
    normal_components = normal.to_a
    local_points = pts.map do |pt|
      point = Geom::Point3d.new(pt)
      delta = point - origin
      distance = normal.dot(delta)
      projected = Geom::Vector3d.new(3.times.map { |index| delta.to_a[index] - normal_components[index] * distance })
      [projected.dot(axis_x), projected.dot(axis_y), 0]
    end

    # Build in a local plane to avoid SketchUp's planarity tolerance being
    # dominated by large translated world coordinates.
    temporary_group = entities.add_group
    begin
      face = temporary_group.entities.add_face(local_points)
    rescue ArgumentError => error
      raise "#{error.message}; local point count=#{local_points.length}, finite=#{local_points.flatten.all? { |value| value.respond_to?(:finite?) && value.finite? }}, sample=#{local_points.first(8).inspect}"
    end
    raise 'Unable to create coplanar face from GEO polygon' unless face
    temporary_group.transform!(Geom::Transformation.axes(origin, axis_x, axis_y, normal))
    face = temporary_group.explode.grep(Sketchup::Face).first
    raise 'GEO face was lost while applying its world transform' unless face

    # 确保面的法向量与输入一致（若方向相反则反转面）
    if face.normal.dot(normal) < 0
      face.reverse!
    end

    return face
  end

  def self.add_2d_face(entities, pts, normal)
    "" "
    Creates a 2D face by rotating vertices to align with a target normal.

    Function:
      Calculates center and axes from vertices and normal, rotates vertices to 2D (z=0), creates a face,
      applies inverse rotation, and explodes the temporary group to get the final face.

    Parameters:
      entities (Sketchup::Entities): Entities container to create the face in.
      pts (Array[Array[Float]]): List of 3D vertices to convert to 2D.
      normal (Geom::Vector3d/Array[Float]): Target normal vector for the 2D face.

    Returns:
      Sketchup::Face or nil: The created 2D-aligned face, nil if creation fails.
    " ""
    center = [0, 0, 0]
    pts.each do |pt|
      center[0] += pt[0]
      center[1] += pt[1]
      center[2] += pt[2]
    end
    center = center.map { |c| c / pts.length }
    axisZ = Geom::Vector3d.new(normal)
    axisX = Geom::Vector3d.new(pts[0]) - Geom::Vector3d.new(center)
    axisY = normal.cross(axisX)
    axisX.length = 1
    axisY.length = 1
    axisZ.length = 1
    rotateMatrix = (Matrix[axisX.to_a, axisY.to_a, axisZ.to_a]).transpose
    pts_new = pts.map { |pt| [pt[0] - center[0], pt[1] - center[1], pt[2] - center[2]] }
    pts_new = pts_new.map { |pt| (Matrix[pt] * rotateMatrix).to_a[0] }
    pts_new = pts_new.map { |pt| [pt[0], pt[1], 0] }

    e = entities.add_face(pts_new)

    # using a new group for transformation
    temp_group = entities.add_group(e)
    transformation = Geom::Transformation.new(Geom::Point3d.new(center), axisX, axisY)
    temp_group.transform! transformation
    temp_group.explode
    exploded_entities = temp_group.explode
    # 从爆炸后的实体中筛选出新的面（原面的副本）
    e = exploded_entities.grep(Sketchup::Face).first

    return e
  end

end
