# Model-page actions: presentation changes only; no geometry/IDF computation.
module MoosasModelPage
  require 'set'
  COMMANDS = %w[recognize_model visualize_entity_type disable_visualize_entity_type show_all_face show_space show_element visualize_one_entity_type update_model_data].freeze

  def self.busy?
    saving? || !!@recognizing || MMR.transform_running? || MoosasAnalysis.main_analysis_running? || (defined?(MoosasVent) && MoosasVent.running?) ||
      (defined?(MoosasIDF) && MoosasIDF.export_running?) || (defined?(MoosasDaylight) && MoosasDaylight.running?) ||
      (defined?(MoosasSurfaceAnalysis) && MoosasSurfaceAnalysis.running?)
  end

  def self.record
    @records ||= {}
    model = Sketchup.active_model
    data = @records[model]
    if !data || data[:semantic] != $current_model
    data = @records[model] = {semantic: $current_model, entities: {}, visualized: false, selected: nil, selected_element: nil}
    end
    data
  end

  # Ignore only our own presentation overrides in Main's geometry fingerprint.
  # An external edit differing from the expected override remains a real change.
  def self.geometry_value(entity, key, current)
    data = (@records || {})[Sketchup.active_model]
    saved = data && data[:entities][entity]
    saved && saved[:expected].key?(key) && saved[:expected][key] == current ? saved[:original][key] : current
  end

  def self.assign(entity, key, value)
    return unless entity.valid?
    saved = record[:entities][entity] ||= {original: {}, expected: {}}
    saved[:original][key] = entity.public_send(key) unless saved[:original].key?(key)
    entity.public_send("#{key}=", value)
    saved[:expected][key] = value
  end

  def self.status
    document = MoosasUtils.settings_document
    MoosasWebDialog.send('model_page_status', {busy: busy?, visualized: record[:visualized], selected_space_id: record[:selected], selected_element: record[:selected_element], context: context, settings_version: document['revision'], drafts: document['drafts'] || {}, draft_revision: document['draft_revision'] || 0})
    if busy? && !@busy_timer
      @busy_timer = UI.start_timer(0.5, true) { publish unless busy? }
    elsif !busy? && @busy_timer
      UI.stop_timer(@busy_timer)
      @busy_timer = nil
    end
  end

  # First calculation attempt after a draft warns and stops. Repeating the
  # same action intentionally uses the last committed RDF snapshot.
  def self.drafts_block_compute?
    data = MoosasUtils.settings_document
    drafts = data['drafts'].is_a?(Hash) ? data['drafts'] : {}
    return false if drafts.empty? || drafts.values.all? { |v| !v.is_a?(Hash) || v.empty? }
    version = data['draft_revision'].to_i
    return false if record[:draft_warning_version] == version
    record[:draft_warning_version] = version
    true
  end

  def self.valid_model!
    unless $current_model && MoosasAnalysis.instance_variable_get(:@recognized_model) == Sketchup.active_model
      raise '请先选择模型并点击 Recognize Model（识别模型）。'
    end
    raise '识别结果已失效，请重新识别模型。' if faces.empty?
  end

  def self.faces
    return [] unless $current_model
    $current_model.get_all_face.select { |f| f.face && f.face.valid? }.uniq { |f| f.face }
  end

  def self.publish
    recover_settings
    valid = $current_model && MoosasAnalysis.instance_variable_get(:@recognized_model) == Sketchup.active_model
    MoosasWebDialog.send('update_model_data', valid ? $current_model.pack_data : {spaces: [], area: 0, height: 0, floor_height: 0})
    status
    publish_svg if valid
  end

  def self.operation(name)
    model = Sketchup.active_model
    old = record[:entities].to_h { |e, s| [e, {original: s[:original].dup, expected: s[:expected].dup}] }
    model.start_operation(name, true)
    begin
      yield
      model.commit_operation
    rescue
      record[:entities] = old
      model.abort_operation
      raise
    end
  end

  def self.restore(keys)
    record[:entities].each do |entity, saved|
      next unless entity.valid?
      keys.each do |key|
        next unless saved[:original].key?(key)
        # Do not overwrite a material/visibility edit made outside this display mode.
        assign(entity, key, saved[:original][key]) if entity.public_send(key) == saved[:expected][key]
      end
    end
  end

  def self.zoom(faces_to_show)
    targets = faces_to_show.to_set
    bounds = Geom::BoundingBox.new
    MoosasRender.traverse_faces(Sketchup.active_model.entities) do |face, path|
      next unless targets.include?(face)
      transform = path.inject(Geom::Transformation.new) { |t, instance| t * instance.transformation }
      face.vertices.each { |vertex| bounds.add(vertex.position.transform(transform)) }
    end
    return if bounds.empty?
    view = Sketchup.active_model.active_view
    previous = view.camera
    radius = [bounds.diagonal * 0.6, 1.0].max
    aspect = view.vpwidth.to_f / [view.vpheight, 1].max
    half_angle = previous.perspective? ? Math.atan(Math.tan(previous.fov * Math::PI / 360.0) * [aspect, 1.0 / aspect, 1.0].min) : 0.5
    distance = previous.perspective? ? radius / Math.sin([half_angle, 0.01].max) : radius * 3
    target = bounds.center
    eye = target.offset(previous.direction.reverse, distance)
    camera = Sketchup::Camera.new(eye, target, previous.up, previous.perspective?)
    if previous.perspective?
      camera.fov = previous.fov
    else
      camera.height = 2 * radius / [aspect, 1.0].min
    end
    view.camera = camera
  end

  def self.set_hidden(entity, value)
    saved = record[:entities][entity] ||= {original: {}, expected: {}}
    saved[:original][:hidden?] = entity.hidden? unless saved[:original].key?(:hidden?)
    entity.hidden = value
    saved[:expected][:hidden?] = value
  end

  def self.show_faces(targets, keep_unselected_edges: false)
    targets = targets.to_set
    all = faces.map(&:face)
    visible_edges = targets.flat_map { |f| f.edges }.to_set
    all.each { |face| set_hidden(face, !targets.include?(face)) }
    edges = all.flat_map(&:edges).uniq
    if keep_unselected_edges
      edges.each { |edge| set_hidden(edge, false) }
    else
      edges.each { |edge| set_hidden(edge, !visible_edges.include?(edge)) }
    end
    MoosasRender.traverse_faces(Sketchup.active_model.entities) do |face, path|
      path.each { |instance| set_hidden(instance, false) } if targets.include?(face)
    end
  end

  def self.restore_presentation
    return if record[:entities].empty?
    operation('Restore model presentation') do
      restore([:material, :back_material])
      record[:entities].each do |entity, saved|
        set_hidden(entity, saved[:original][:hidden?]) if entity.valid? && saved[:original].key?(:hidden?) && entity.hidden? == saved[:expected][:hidden?]
      end
    end
    record[:visualized] = false
    record[:selected] = nil
  end

  def self.handle(command, params=[])
    return publish if command == 'update_model_data'
    @last_error = nil
    raise '模型任务正在运行，请稍后重试。' if busy?
    if command == 'recognize_model'
      # With no active selection, Remodel/Recognize applies to the whole model.
      # A non-empty selection continues to scope recognition to those entities.
      @recognizing = true
      status
      started = MMR.recognize_floor_async(true) do |success|
        @recognizing = false
        MoosasWebDialog.send('model_page_error', {message: MMR.instance_variable_get(:@recognition_error) || '识别失败，请检查模型与任务日志。'}) unless success
        publish
      end
      raise '无法启动模型识别。' unless started
      return true
    end
    valid_model! unless %w[visualize_entity_type disable_visualize_entity_type].include?(command)
    case command
    when 'visualize_entity_type'
      MoosasRender.visualize_entity_type($current_model)
      record[:visualized] = true
    when 'disable_visualize_entity_type'
      MoosasRender.disable_visualize_entity_type($current_model)
      record[:visualized] = false
    when 'show_all_face'
      operation('Model: show all recognized faces') { show_faces(faces.map(&:face)) }
      record[:selected] = nil
      record[:selected_element] = nil
      zoom(faces.map(&:face))
    when 'show_space'
      index = $current_model.spaces.index { |s| s.id.to_s == params[0].to_s }
      raise '空间不存在，请刷新 Model 页面。' unless index
      space = $current_model.spaces[index]
      targets = space.get_all_face.map(&:face).select { |f| f && f.valid? }
      raise '该空间没有可显示的面，请重新识别。' if targets.empty?
      # Keep the floor-plan wireframe of other spaces visible for orientation;
      # only their recognized faces are hidden.
      operation('Model: show selected space with context edges') do
        show_faces(targets, keep_unselected_edges: true)
      end
      record[:selected] = space.id.to_s
      record[:selected_element] = nil
      $space_select_index = index
      zoom(targets)
    when 'show_element'
      element = $current_model.get_all_face.find { |f| f.respond_to?(:uid) && f.uid.to_s == params[0].to_s }
      raise '墙窗不存在，请刷新 Model 页面。' unless element
      targets = $current_model.get_all_face.select do |face|
        face.respond_to?(:uid) && face.uid.to_s == params[0].to_s && face.face && face.face.valid?
      end.map(&:face).uniq
      raise '该墙窗没有可显示的面，请重新识别。' if targets.empty?
      operation('Model: isolate element') { show_faces(targets) }
      settings = (element.settings || {}).dup
      settings['u_value'] ||= settings['u']
      record[:selected_element] = {'id'=>element.uid.to_s, 'type'=>params[1].to_s, 'settings'=>settings}
      record[:selected] = nil
      zoom(targets)
    when 'visualize_one_entity_type'
      targets = faces.select { |mf| mf.type == params[0].to_i }.map(&:face)
      operation('Model: isolate surface type') { show_faces(targets) }
      record[:selected] = nil
      record[:selected_element] = nil
      zoom(targets)
    end
    status
    true
  rescue => e
    @last_error = {message: e.message, backtrace: e.backtrace}
    @recognizing = false unless MMR.transform_running?
    MoosasWebDialog.send('model_page_error', {message: e.message})
    status
    false
  end
end
require_relative 'MoosasSpaceEditor'
