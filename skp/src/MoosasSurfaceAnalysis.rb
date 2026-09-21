require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require 'tmpdir'

# Coordinates Python-backed direct-sun and radiation analysis for SketchUp grids.
class MoosasSurfaceAnalysis
  SCHEMA_VERSION = 1
  INCH_TO_METRE = 0.0254
  class << self
    attr_reader :last_workspace, :last_result
  end

  def self.running?; @running == true; end

  def self.start(analysis, sunhour_parameters = nil)
    return false if running? || MMR.transform_running? || (defined?(MoosasDaylight) && MoosasDaylight.running?)
    raise "Unsupported surface analysis: #{analysis}" unless %w[sunhour radiation].include?(analysis)
    model = Sketchup.active_model
    grids = selected_grids(model)
    grids = MoosasGrid.fit_grids() if grids.empty?
    grids = Array(grids).select { |grid| valid_grid?(grid) }
    raise 'No valid analysis grids' if grids.empty?
    @running, @last_result = true, nil
    submit(analysis, model, grids, sunhour_parameters)
  rescue StandardError => error
    fail_job(error.message)
    false
  end

  def self.selected_grids(model)
    model.selection.grep(Sketchup::Group).select { |entity| valid_grid?(entity) }
  end

  def self.valid_grid?(grid)
    grid && !grid.deleted? && grid.attribute_dictionary('grid', false)
  end

  def self.submit(analysis, model, grids, sunhour_parameters)
    parent = File.join(MPath::DATA, 'surface-analysis', 'jobs')
    FileUtils.mkdir_p(parent)
    workspace = Dir.mktmpdir("#{analysis}-", parent)
    @last_workspace = workspace
    scene_path = File.join(workspace, 'scene.geo')
    export_scene(model, scene_path)
    grid_payload = serialize_grids(grids)
    request = {
      'schema_version' => SCHEMA_VERSION, 'job_id' => SecureRandom.uuid, 'analysis' => analysis,
      'scene_path' => scene_path, 'location' => location_payload, 'grids' => grid_payload,
      'sunhour_parameters' => sunhour_parameters || MoosasSunHour::DEFAULT_PARAMETERS,
      'cumulative_sky_path' => File.join(MPath::SKY, "cumsky_#{MoosasWeather.station_id}.csv")
    }
    request_path = File.join(workspace, 'request.json')
    File.write(request_path, JSON.pretty_generate(request), encoding: 'UTF-8')
    snapshot = { model: model, grids: grids, scene_signature: Digest::SHA256.file(scene_path).hexdigest,
                 grid_signature: Digest::SHA256.hexdigest(JSON.generate(grid_payload)) }
    code = ['from skp.scripts.surface_analysis_job import execute', "execute(#{request_path.to_json})"]
    started = MoosasUtils.exec_python_async('surface_analysis.py', code, workspace: workspace, console: true) do |process_success|
      complete(process_success, request, snapshot)
    end
    raise 'Could not launch surface-analysis Python process' unless started
    Sketchup.status_text = analysis == 'sunhour' ? 'Sun-hour analysis running' : 'Radiation analysis running'
    true
  end

  def self.location_payload
    station = MoosasWeather.singleton && MoosasWeather.singleton.station_info
    raise 'No active weather station' unless station && station['lat'] && station['lng']
    { 'latitude' => Float(station['lat']), 'longitude' => Float(station['lng']) }
  end

  def self.serialize_grids(grids)
    grids.map do |grid|
      dictionary = grid.attribute_dictionary('grid', false)
      nodes = dictionary['nodes']
      raise 'Grid has no nodes' unless nodes.is_a?(Array)
      normal_values = dictionary['norm']
      raise 'Grid has no SketchUp face normal; recreate it from the analysis face' unless normal_values.is_a?(Array)
      normal = Geom::Vector3d.new(normal_values)
      raise 'Grid has a zero SketchUp face normal; recreate it from the analysis face' if normal.length.zero?
      normal.length = 1
      { 'id' => grid.persistent_id.to_s, 'normal' => normal.to_a,
        'nodes' => nodes.map { |row| row.map { |point| point ? point.to_a.map { |value| value * INCH_TO_METRE } : nil } } }
    end
  end

  def self.grid_signature(grids)
    Digest::SHA256.hexdigest(JSON.generate(serialize_grids(grids)))
  end

  # Visible groups/components marked as analysis grids are excluded from occlusion.
  def self.export_scene(model, destination)
    records = []
    rejected = []
    walk_scene(model.entities) do |face, path|
      next unless MMR.user_visible?(face) && path.all? { |parent| MMR.user_visible?(parent) }
      transformation = path.inject(Geom::Transformation.new) { |total, parent| total * parent.transformation }
      normal = face.normal.transform(transformation)
      normal.length = 1 unless normal.length.zero?
      # Keep the analysis scene triangulated for compatibility with existing
      # Moosas pipelines; MoosasRad also accepts polygon loops and fh holes.
      source_id = "surface_#{(path + [face]).map(&:persistent_id).join('_')}"
      exported = MMR.geo_export_face(face, transformation, source_id, force_triangles: true)
      rejected.concat(exported.fetch(:rejected, []))
      exported[:records].each { |record| records << MMRGeoExport.serialize(record, MMR.get_category(face), normal) }
    end
    raise 'No visible model faces available for analysis' if records.empty?
    File.write(destination, records.join, encoding: 'UTF-8')
    File.write(destination + '.export.json', JSON.pretty_generate({triangles: records.length, rejected: rejected}), encoding: 'UTF-8')
  end

  def self.walk_scene(entity, path = [], &block)
    case entity
    when Sketchup::Face then block.call(entity, path)
    when Sketchup::Group
      return if entity.attribute_dictionary('grid', false) || entity.get_attribute('MoosasSurfaceAnalysis', 'visualization', false) || entity.get_attribute('MoosasDaylight', 'visualization', false)
      entity.entities.each { |child| walk_scene(child, path + [entity], &block) }
    when Sketchup::ComponentInstance
      return if entity.attribute_dictionary('grid', false) || entity.get_attribute('MoosasSurfaceAnalysis', 'visualization', false) || entity.get_attribute('MoosasDaylight', 'visualization', false)
      entity.definition.entities.each { |child| walk_scene(child, path + [entity], &block) }
    when Sketchup::Entities, Sketchup::Selection, Enumerable
      entity.each { |child| walk_scene(child, path, &block) }
    end
  end

  def self.complete(process_success, request, snapshot)
    begin
      result_path = File.join(@last_workspace, 'result.json')
      raise 'Python exited without result.json' unless File.file?(result_path)
      result = JSON.parse(File.read(result_path, encoding: 'UTF-8'))
      raise(result['error'] || 'Surface-analysis Python job failed') unless process_success && result['success']
      raise 'Mismatched surface-analysis result' unless result['schema_version'] == SCHEMA_VERSION && result['job_id'] == request['job_id']
      verify_snapshot(snapshot)
      apply_result(result, snapshot[:grids])
      @last_result = result
      Sketchup.status_text = request['analysis'] == 'sunhour' ? 'Sun-hour analysis complete' : 'Radiation analysis complete'
      @running = false
    rescue StandardError => error
      fail_job("#{error.message} (#{@last_workspace})")
    end
  end

  def self.verify_snapshot(snapshot)
    raise 'Model changed during simulation; result was not drawn' unless Sketchup.active_model == snapshot[:model]
    raise 'Analysis grid changed during simulation; result was not drawn' unless grid_signature(snapshot[:grids]) == snapshot[:grid_signature]
    verification_scene = File.join(@last_workspace, 'verify_scene.geo')
    export_scene(snapshot[:model], verification_scene)
    raise 'Scene changed during simulation; result was not drawn' unless Digest::SHA256.file(verification_scene).hexdigest == snapshot[:scene_signature]
  end

  def self.apply_result(result, grids)
    by_id = result.fetch('grids').each_with_object({}) { |entry, index| index[entry.fetch('id').to_s] = entry }
    grid_type = result.fetch('analysis') == 'radiation' ? 'radiance' : 'sunhour'
    model = Sketchup.active_model
    model.start_operation(result['analysis'] == 'sunhour' ? 'Sun-hour results' : 'Radiation results', true)
    begin
      grids.each do |grid|
        entry, dictionary = by_id.fetch(grid.persistent_id.to_s), grid.attribute_dictionary('grid', false)
        dictionary['results'], dictionary['valueRange'], dictionary['type'] = entry.fetch('values'), Float(result.fetch('value_range')), grid_type
        dictionary['result_mean'] = Float(entry.fetch('statistics').fetch('mean'))
        dictionary['result_min'] = Float(entry.fetch('statistics').fetch('minimum'))
        dictionary['result_max'] = Float(entry.fetch('statistics').fetch('maximum'))
        MoosasGrid.color_grid(grid)
      end
      model.selection.clear; model.selection.add(grids); draw_scale(result, grids, grid_type); model.commit_operation
    rescue Exception
      model.abort_operation
      raise
    end
  end

  def self.draw_scale(result, grids, grid_type)
    station = MoosasWeather.singleton.station_info
    description = result['analysis'] == 'sunhour' ? "Direct Sun Hour\nLocation:#{station['city']}" : "Solar Radiation Intensity\nLocation:#{station['city']}\nPeriod:Annual"
    scale = MoosasGridScaleRender.new(0, Float(result['value_range']), description, result['unit'], MoosasGrid.color_setting.fetch(grid_type)['colours'])
    entities = Sketchup.active_model.active_entities
    before = entities.to_a
    scale.draw_panel(grids)
    (entities.to_a - before).grep(Sketchup::Group).each do |legend|
      legend.name = 'Moosas Surface Analysis Legend'
      legend.set_attribute('MoosasSurfaceAnalysis', 'visualization', true)
    end
  end

  def self.fail_job(message)
    @running = false
    Sketchup.status_text = "Surface analysis failed: #{message}"
    p "Surface analysis failed: #{message}"
  end
end
