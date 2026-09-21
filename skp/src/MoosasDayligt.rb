require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require 'time'

class MoosasDaylight
  SCHEMA_VERSION = 1
  INCHES_PER_METRE = 1.0 / 0.0254
  RESULT_ATTRIBUTE = 'MoosasDaylight'
  class << self
    attr_reader :last_workspace, :last_result
  end

  def self.running?; @running == true; end
  def self.local_analysis_daylight(_legacy_index = nil); start; end

  def self.start(options = nil)
    raise '采光任务正在运行，请稍候。' if running?
    raise '模型参数正在保存，请稍后重试。' if defined?(MoosasModelPage) && MoosasModelPage.saving?
    if defined?(MoosasModelPage) && MoosasModelPage.drafts_block_compute?
      raise '存在未保存的参数修改，请先 Save；再次运行将使用已保存版本。'
    end
    raise '模型正有其他计算任务运行。' if defined?(MoosasModelPage) && MoosasModelPage.busy?
    raise '模型变换或导出正在运行。' if MMR.transform_running? || (defined?(MoosasIDF) && MoosasIDF.export_running?)

    model, semantic = Sketchup.active_model, $current_model
    raise '请先识别当前模型。' unless semantic && MoosasAnalysis.instance_variable_get(:@recognized_model) == model
    source_files = Array(MoosasAnalysis.instance_variable_get(:@recognized_files))
    raise '当前识别 RDF 不存在，请重新识别模型。' if source_files.empty? || source_files.any? { |file| !File.file?(file) }
    signature = MoosasAnalysis.geometry_signature(model)
    raise '模型几何已变化，请重新识别后再计算。' unless MoosasAnalysis.instance_variable_get(:@recognized_signature) == signature
    revision = MoosasAnalysis.geometry_revision(model)
    recognized_revision = MoosasAnalysis.instance_variable_get(:@recognized_revision)
    raise '模型几何版本已变化，请重新识别后再计算。' if recognized_revision && recognized_revision != revision

    active_id = defined?(MoosasModelPage) ? MoosasModelPage.record[:selected].to_s : ''
    valid_ids = semantic.spaces.map { |space| space.id.to_s }
    active_id = '' unless valid_ids.include?(active_id)
    labels = $language == 'Chinese' ? ['当前空间', '全部空间', '指定空间'] : ['Current space', 'All spaces', 'Specific spaces']
    default_mode = active_id.empty? ? labels[1] : labels[0]
    prompts = $language == 'Chinese' ? ['分析范围', '空间 ID（多个用逗号分隔）', '网格间距 (m)', '工作面高度 (m)', '日期时间（本地）', '天空模型', '室外水平漫射照度 (lux)'] : ['Scope', 'Space IDs (comma-separated)', 'Grid spacing (m)', 'Workplane height (m)', 'Local date/time', 'Sky model', 'Exterior diffuse illuminance (lux)']
    defaults = [default_mode, active_id, '0.5', '0.72', '2026-01-20 14:00', 'Overcast (-c)', '15000']
    lists = [labels.join('|'), '', '', '', '', 'Overcast (-c)|Intermediate (-i)|Clear (-s)', '']
    if options
      scope = (options['scope'] || options[:scope] || (active_id.empty? ? 'all' : 'current')).to_s
      mode = {'current'=>labels[0], 'all'=>labels[1], 'specific'=>labels[2]}[scope] || scope
      ids_text = options['space_ids'] || options[:space_ids] || ''
      grid_size = options['grid_size'] || options[:grid_size] || 0.5
      grid_offset = options['grid_offset'] || options[:grid_offset] || 0.72
      datetime_text = options['datetime'] || options[:datetime] || '2026-01-20 14:00'
      sky_type = options['sky_type'] || options[:sky_type] || '-c'
      sky_label = "Sky (#{sky_type})"
      diffuse = options['diffuse_illuminance'] || options[:diffuse_illuminance] || 15000
    else
      values = UI.inputbox(prompts, defaults, lists, $language == 'Chinese' ? 'Radiance 采光模拟' : 'Radiance daylight simulation')
      return false unless values
      mode, ids_text, grid_size, grid_offset, datetime_text, sky_label, diffuse = values
      sky_type = sky_label[/\((-[a-z+]+)\)/, 1]
    end
    space_ids = case mode
                when labels[0]
                  raise 'Model 页尚未选中空间；请选择全部空间或指定空间。' if active_id.empty?
                  [active_id]
                when labels[1]
                  nil
                when labels[2]
                  Array(ids_text).flat_map { |value| value.to_s.split(/[\s,;]+/) }.reject(&:empty?).uniq
                else
                  raise '无效的分析范围。'
                end
    if space_ids && (space_ids.empty? || (space_ids - valid_ids).any?)
      raise '空间 ID 列表为空或含有未知 ID。'
    end
    grid_size, grid_offset, diffuse = Float(grid_size), Float(grid_offset), Float(diffuse)
    raise '网格间距必须大于 0，工作面高度不能为负，漫射照度必须大于 0。' unless grid_size.finite? && grid_size > 0 && grid_offset.finite? && grid_offset >= 0 && diffuse.finite? && diffuse > 0
    datetime = Time.strptime(datetime_text.to_s, '%Y-%m-%d %H:%M').strftime('%Y-%m-%dT%H:%M:00+08:00')

    station = MoosasWeather.singleton && MoosasWeather.singleton.station_info
    raise '请选择有效的气象站。' unless station && station['lat'] && station['lng']
    settings_version = MoosasUtils.settings_document['revision'].to_i
    @request_id = SecureRandom.uuid
    parent = File.join(MPath::DATA, 'jobs')
    FileUtils.mkdir_p(parent)
    @last_workspace = File.join(parent, "daylight-#{@request_id}")
    FileUtils.mkdir_p(@last_workspace)
    source = source_files.first
    rdf_snapshot = File.join(@last_workspace, 'model.ttl')
    FileUtils.cp(source, rdf_snapshot)
    snapshot = {'model_guid'=>model.guid.to_s, 'geometry_signature'=>signature,
                'geometry_version'=>revision, 'rdf_sha256'=>Digest::SHA256.file(rdf_snapshot).hexdigest}
    request = {
      'schema_version'=>SCHEMA_VERSION, 'request_id'=>@request_id, 'space_ids'=>space_ids,
      'rdf_path'=>rdf_snapshot, 'model_snapshot'=>snapshot, 'settings_version'=>settings_version,
      'location'=>{'station_id'=>MoosasWeather.station_id.to_s, 'city'=>station['city'].to_s,
        'state'=>station['province'].to_s, 'latitude'=>Float(station['lat']), 'longitude'=>Float(station['lng']),
        'altitude'=>Float(station['ele'] || 0), 'pressure'=>Float(station['airP'] || 101325)},
      'parameters'=>{'grid_size'=>grid_size, 'grid_offset'=>grid_offset, 'datetime'=>datetime,
        'sky_type'=>sky_type, 'diffuse_illuminance'=>diffuse, 'timezone_hours'=>8.0, 'threshold_lux'=>300.0}
    }
    @snapshot = {model: model, signature: signature, revision: revision, settings_version: settings_version,
                 rdf_sha256: snapshot['rdf_sha256'], source: source, request_id: @request_id}
    @running, @last_result, @last_error = true, nil, nil
    File.write(File.join(@last_workspace, 'request.json'), JSON.pretty_generate(request), encoding: 'UTF-8')
    File.write(File.join(@last_workspace, 'settings.json'), JSON.pretty_generate(request['parameters']), encoding: 'UTF-8')
    notify('loading')
    request_path = File.join(@last_workspace, 'request.json')
    started = MoosasUtils.exec_python_async('daylight_job.py', [
      'from skp.scripts.daylight_job import run_file', "run_file(#{request_path.to_json})"
    ], workspace: @last_workspace, console: true) { |success| complete(success, request) }
    raise '无法启动 Python 采光任务。' unless started
    start_progress_poll(@request_id)
    true
  rescue StandardError => error
    fail_job(error.message) unless running?
    false
  end

  def self.start_progress_poll(request_id)
    poll = nil
    poll = proc do
      if running? && @request_id == request_id
        begin
          progress = JSON.parse(File.read(File.join(@last_workspace, 'progress.json'), encoding: 'UTF-8'))
          notify(progress['stage']) if progress['request_id'] == request_id
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end
        UI.start_timer(0.5, false, &poll)
      end
    end
    UI.start_timer(0.5, false, &poll)
  end

  def self.complete(process_success, request)
    result_path = File.join(@last_workspace, 'result.json')
    raise 'Python 未生成 result.json；请查看任务日志。' unless File.file?(result_path)
    result = JSON.parse(File.read(result_path, encoding: 'UTF-8'))
    raise(result['error'] || 'Radiance 计算失败。') unless process_success && result['success']
    raise '采光结果 request_id 不匹配。' unless result['request_id'] == @request_id
    raise '采光结果任务快照不匹配。' unless result['model_snapshot'] == request['model_snapshot'] && result['settings_version'].to_i == @snapshot[:settings_version]
    raise '采光任务没有返回空间结果。' if result['spaces'].empty?
    unless current_snapshot?
      @running = false
      notify('stale', '模型或设置在模拟期间发生变化；结果保留在任务目录，没有绘制。')
      return false
    end
    apply_result(result)
    @last_result = result
    @running = false
    notify('complete', result)
    true
  rescue StandardError => error
    fail_job(error.message)
    false
  end

  def self.current_snapshot?
    return false unless Sketchup.active_model == @snapshot[:model]
    return false unless MoosasAnalysis.geometry_signature(@snapshot[:model]) == @snapshot[:signature]
    return false unless MoosasAnalysis.geometry_revision(@snapshot[:model]) == @snapshot[:revision]
    return false unless MoosasUtils.settings_document['revision'].to_i == @snapshot[:settings_version]
    files = Array(MoosasAnalysis.instance_variable_get(:@recognized_files))
    return false unless files.include?(@snapshot[:source]) && File.file?(@snapshot[:source])
    Digest::SHA256.file(@snapshot[:source]).hexdigest == @snapshot[:rdf_sha256]
  end

  def self.apply_result(result)
    model, entities = Sketchup.active_model, Sketchup.active_model.entities
    model.start_operation('Draw Moosas daylight result', true)
    begin
      entities.grep(Sketchup::Group).select { |group| group.get_attribute(RESULT_ATTRIBUTE, 'visualization', false) }.each(&:erase!)
      result['spaces'].each do |space|
        group = entities.add_group
        group.name = "Moosas Daylight #{space['space_id']}"
        group.set_attribute(RESULT_ATTRIBUTE, 'visualization', true)
        group.set_attribute(RESULT_ATTRIBUTE, 'request_id', result['request_id'])
        group.set_attribute(RESULT_ATTRIBUTE, 'space_id', space['space_id'])
        group.set_attribute(RESULT_ATTRIBUTE, 'metric_kind', space['metric_kind'])
        space['points'].each do |entry|
          previous_faces = group.entities.grep(Sketchup::Face).map(&:persistent_id)
          coords = entry['polygon'].map { |point| Geom::Point3d.new(*point.map { |value| Float(value) * INCHES_PER_METRE }) }
          outer_face = group.entities.add_face(coords)
          next unless outer_face
          Array(entry['holes']).each do |hole|
            hole_points = hole.map { |point| Geom::Point3d.new(*point.map { |value| Float(value) * INCHES_PER_METRE }) }
            hole_face = group.entities.add_face(hole_points)
            hole_face.erase! if hole_face && hole_face.valid?
          end
          value = space['metric_kind'] == 'daylight_factor_percent' ? Float(entry['illuminance']) / Float(result['reference_illuminance']) * 100.0 : Float(entry['illuminance'])
          material = result_color(value, space['metric_kind'] == 'daylight_factor_percent' ? 15.0 : 10000.0)
          group.entities.grep(Sketchup::Face).reject { |candidate| previous_faces.include?(candidate.persistent_id) }.each do |cell_face|
            cell_face.material = material
            cell_face.back_material = material
            cell_face.set_attribute(RESULT_ATTRIBUTE, 'grid_id', entry['grid_id'])
          end
        end
      end
      draw_legend(entities, result)
      model.commit_operation
    rescue Exception
      model.abort_operation
      raise
    end
  end

  def self.result_color(value, maximum)
    ratio = [[Float(value) / maximum, 0.0].max, 1.0].min
    if ratio < 0.5
      Sketchup::Color.new(40, (100 + ratio * 260).to_i, (220 - ratio * 340).to_i)
    else
      Sketchup::Color.new(((ratio - 0.5) * 440).to_i, (230 - (ratio - 0.5) * 300).to_i, 50)
    end
  end

  def self.draw_legend(entities, result)
    legend = entities.add_group
    legend.name = 'Moosas Daylight Legend'
    legend.set_attribute(RESULT_ATTRIBUTE, 'visualization', true)
    legend.set_attribute(RESULT_ATTRIBUTE, 'request_id', result['request_id'])
    bounds = Sketchup.active_model.bounds
    legend.transformation = Geom::Transformation.new(
      Geom::Point3d.new(bounds.min.x, bounds.min.y, bounds.max.z + 12.0)
    ) unless bounds.empty?
    first = result['spaces'].first
    label = first['metric_kind'] == 'daylight_factor_percent' ? 'Daylight factor (%)' : 'Illuminance (lux)'
    stats = result['spaces'].map do |space|
      average = space['daylight_factor_percent'] || space['average_illuminance']
      unit = space['daylight_factor_percent'] ? '%' : 'lux'
      "#{space['space_id']}: avg #{format('%.1f', average)} #{unit}, min #{format('%.1f', space['minimum_illuminance'])} lux, max #{format('%.1f', space['maximum_illuminance'])} lux, n=#{space['point_count']}"
    end
    legend.entities.add_text("#{label} — request #{result['request_id']}\n#{stats.join("\n")}", Geom::Point3d.new(0, 30, 0))
    maximum = first['metric_kind'] == 'daylight_factor_percent' ? 15.0 : 10000.0
    10.times do |index|
      x0, x1 = index * 12.0, (index + 1) * 12.0
      patch = legend.entities.add_face(
        Geom::Point3d.new(x0, 0, 0), Geom::Point3d.new(x1, 0, 0),
        Geom::Point3d.new(x1, 10, 0), Geom::Point3d.new(x0, 10, 0)
      )
      color = result_color(maximum * index / 9.0, maximum)
      patch.material = color if patch
      patch.back_material = color if patch
    end
    units = first['metric_kind'] == 'daylight_factor_percent' ? '%' : 'lux'
    legend.entities.add_text("0 #{units}", Geom::Point3d.new(0, -14, 0))
    legend.entities.add_text("#{maximum.to_i} #{units}", Geom::Point3d.new(96, -14, 0))
  end

  def self.notify(stage, payload = nil)
    MoosasWebDialog.send('daylight_status', {'request_id'=>@request_id, 'running'=>running?, 'stage'=>stage,
      'workspace'=>@last_workspace, 'message'=>payload.is_a?(String) ? payload : nil})
    if stage == 'complete' && payload.is_a?(Hash)
      summary = {'request_id'=>payload['request_id'], 'metric_kind'=>payload['metric_kind'],
        'spaces'=>payload['spaces'].map do |space|
          space.select { |key, _| %w[space_id point_count effective_area average_illuminance minimum_illuminance maximum_illuminance uniformity satisfied_fraction metric_kind daylight_factor_percent].include?(key) }
        end}
      MoosasWebDialog.send('daylight_result', summary)
    end
    MoosasWebDialog.send('daylight_error', {'request_id'=>@request_id, 'message'=>payload}) if stage == 'failed'
  rescue StandardError => error
    p "Daylight status delivery failed: #{error.message}"
  end

  def self.fail_job(message)
    @running = false
    @last_error = message
    notify('failed', message)
    p "Daylight simulation failed: #{message}"
  end
end
