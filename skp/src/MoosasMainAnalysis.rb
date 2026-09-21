# Main-page adapter: model snapshots and asynchronous Python jobs only.
require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'
require 'securerandom'

module MoosasAnalysis
  class RecognitionRequired < StandardError; end
  class GeometryObserver < Sketchup::ModelObserver
    def onTransactionCommit(model); MoosasAnalysis.geometry_revision(model); end
    def onTransactionUndo(model); MoosasAnalysis.geometry_revision(model); end
    def onTransactionRedo(model); MoosasAnalysis.geometry_revision(model); end
  end

  class ContextObserver < Sketchup::AppObserver
    def onActivateModel(model); MoosasAnalysis.context_changed; end
  end

  def self.context_changed
    @context_revision = (@context_revision || 0) + 1
  end

  def self.geometry_revision(model)
    @geometry_versions ||= {}
    record = @geometry_versions[model]
    signature = geometry_signature(model)
    unless record
      observer = GeometryObserver.new
      model.add_observer(observer)
      record = @geometry_versions[model] = {signature: signature, revision: 0, observer: observer}
    end
    if record[:signature] != signature
      record[:signature] = signature
      record[:revision] += 1
    end
    record[:revision]
  end

  unless @context_observer
    @context_observer = ContextObserver.new
    Sketchup.add_observer(@context_observer)
  end

  # Compatibility for callers of the former synchronous Main entrypoint.
  def self.main_analysis(recognize, building_type, radiation)
    main_analysis_async(($ui_settings || {}).merge('selectBuildingType'=>building_type,
      'recognize'=>[true, 'true'].include?(recognize), 'radiation'=>[true, 'true'].include?(radiation)))
  end
  def self.main_analysis_running?
    !!@main_running
  end

  def self.geometry_signature(model)
    digest = Digest::SHA256.new
    walk = nil
    walk = proc do |entities, stack|
      entities.each do |entity|
        next unless entity.valid?
        next if entity.is_a?(Sketchup::Group) && entity.get_attribute('MoosasDaylight', 'visualization', false)
        hidden = entity.hidden? if entity.respond_to?(:hidden?)
        hidden = MoosasModelPage.geometry_value(entity, :hidden?, hidden) if defined?(MoosasModelPage)
        digest << [entity.persistent_id, hidden, entity.layer.name, entity.layer.visible?].inspect if entity.respond_to?(:hidden?)
        if entity.is_a?(Sketchup::Face)
          digest << entity.loops.map { |loop| loop.vertices.map { |v| v.position.to_a } }.inspect
          front, back = entity.material, entity.back_material
          if defined?(MoosasModelPage)
            front = MoosasModelPage.geometry_value(entity, :material, front)
            back = MoosasModelPage.geometry_value(entity, :back_material, back)
          end
          digest << [front&.name, front&.alpha, back&.name, back&.alpha].inspect
        elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          definition = entity.definition
          digest << entity.transformation.to_a.inspect
          walk.call(definition.entities, stack + [definition]) unless stack.include?(definition)
        end
      end
    end
    walk.call(model.entities, [])
    digest.hexdigest
  end

  def self.register_recognition(model, rdf_files)
    @recognized_model = model
    @recognized_signature = geometry_signature(model)
    @recognized_revision = geometry_revision(model)
    # Editable RDF is separate from immutable recognition/analysis job snapshots.
    parent = File.join(MPath::DATA, 'models')
    FileUtils.mkdir_p(parent)
    directory = Dir.mktmpdir('model-', parent)
    @recognized_files = rdf_files.each_with_index.map do |source, i|
      target = File.join(directory, "model-#{i}.ttl")
      FileUtils.cp(source, target)
      target
    end
    MMR.instance_variable_set(:@last_rdf_files, @recognized_files.dup)
    @baseline_settings = $current_model.spaces.to_h { |s| [s.id.to_s, s.instance_variable_get(:@main_settings_legacy) ? nil : s.settings.dup] }
  end

  def self.main_emit(command, data)
    dialog = MoosasWebDialog.dialog
    MoosasWebDialog.send(command, data) if dialog && dialog.visible?
  rescue => e
    p "Main analysis UI delivery: #{e.message}"
  end

  def self.main_status(stage)
    @main_status = {'request_id' => @main_id, 'stage' => stage, 'running' => !!@main_running}
    main_emit('main_analysis_status', @main_status)
  end

  def self.restore_main_analysis
    if @main_model == Sketchup.active_model
      main_emit('main_analysis_result', @main_result) if @main_result && geometry_signature(@main_model) == @main_signature
      main_emit('main_analysis_error', @main_error.merge('restored'=>true)) if @main_error
      main_emit('main_analysis_status', @main_status) if @main_status
    end
  end

  def self.main_fail(error, code: nil)
    @main_running = false
    @main_error = {'request_id' => @main_id, 'message' => error.to_s, 'job_dir' => @main_dir, 'code'=>code}
    if @main_dir && !File.file?(File.join(@main_dir, 'error.json'))
      File.write(File.join(@main_dir, 'error.json'), JSON.generate(@main_error), :encoding=>'UTF-8')
    end
    main_emit('main_analysis_error', @main_error)
    main_status('failed')
    false
  end

  def self.main_analysis_async(settings)
    raise '空间参数正在保存，请稍后重试。' if defined?(MoosasModelPage) && MoosasModelPage.saving?
    raise '存在未保存的参数修改，请点击 Save 后再分析；再次点击将使用已保存版本。' if defined?(MoosasModelPage) && MoosasModelPage.drafts_block_compute?
    if @main_running
      main_emit('main_analysis_status', @main_status)
      return false
    end
    @main_id = settings['request_id'] || SecureRandom.uuid
    @main_model = Sketchup.active_model
    @main_context_revision = @context_revision || 0
    @main_error = @main_result = @main_dir = nil
    if settings['recognize'] == false
      valid = $current_model && @recognized_model == @main_model && @recognized_files &&
        !@recognized_files.empty? && @recognized_files.all? { |path| File.file?(path) } &&
        @recognized_signature == geometry_signature(@main_model) &&
        (!@recognized_revision || @recognized_revision == geometry_revision(@main_model))
      unless valid
        raise RecognitionRequired, '请先识别当前模型，或勾选 Recognize（识别模型）后再分析。 / Please recognize the model first, or enable Recognize before Analysis.'
      end
    end
    # IDF export is only a mutual-exclusion check, never part of Main's computation.
    raise 'Another model simulation/export is running' if MMR.transform_running? || (defined?(MoosasIDF) && MoosasIDF.export_running?) ||
      (defined?(MoosasDaylight) && MoosasDaylight.running?) || (defined?(MoosasSurfaceAnalysis) && MoosasSurfaceAnalysis.running?)
    names = {'居住建筑'=>'RESIDENTIAL', 'Residence'=>'RESIDENTIAL', '办公建筑'=>'OFFICE', 'Office'=>'OFFICE',
             '酒店建筑'=>'HOTEL', 'Hotel'=>'HOTEL', '学校建筑'=>'SCHOOL', 'School'=>'SCHOOL', '商场建筑'=>'COMMERCIAL', 'Commercial'=>'COMMERCIAL'}
    type = names[settings['selectBuildingType']] || settings['selectBuildingType']
    raise '建筑类型暂不支持 / Unsupported building type' unless names.values.include?(type)
    standard = settings['selectStandard'].to_s
    raise 'Unsupported standard' unless standard.include?('51350-2019')
    $ui_settings = ($ui_settings || {}).merge(settings.reject { |key, _| key == 'request_id' })
    $ui_settings['selectBuildingType'] = MoosasStandard::STANDARDNAME.key(type)
    $ui_settings['selectStandard'] = MoosasStandard::STANDARDNAME.key('GB/T51350-2019')
    station_id = settings['selectCity'].to_s
    station = MoosasWeather.stations[station_id]
    raise '请选择有效气象站 / Select a weather station' unless station
    raise 'recognize and radiation must be boolean' unless [true, false].include?(settings['recognize']) && [true, false].include?(settings['radiation'])
    @main_request = {'schema_version'=>1, 'request_id'=>@main_id, 'building_type'=>type,
      'standard'=>'GB/T51350-2019', 'require_radiation'=>settings['radiation'],
      'weather'=>{'csv_path'=>File.join(MPath::WEATHER, station_id + '.csv'),
        'sky_path'=>File.join(MPath::SKY, 'cumsky_' + station_id + '.csv'), 'sky_station_id'=>station_id,
        'location'=>{'station_id'=>station_id, 'city'=>station['city'], 'state'=>station['province'],
          'latitude'=>station['lat'], 'longitude'=>station['lng'], 'altitude'=>station['ele'], 'pressure'=>station['airP']}}}
    epw = File.join(MPath::WEATHER, station_id + '.epw')
    @main_request['weather'] = {'epw_path'=>epw} if File.file?(epw)
    if settings['recognize']
      raise '请先选择需要识别的几何体 / Select geometry first' if @main_model.selection.empty?
      create_main_job
      @main_running = true
      main_status('recognizing')
      started = MMR.recognize_floor_async(true, main_analysis: true, workspace: File.join(@main_dir, 'recognition')) do |success|
        success ? launch_main_analysis : main_fail(MMR.instance_variable_get(:@recognition_error) || 'Model recognition failed')
      end
      main_fail('Could not start recognition') unless started
    else
      raise '请先识别当前模型 / Recognize the current model first' unless $current_model && @recognized_model == @main_model
      raise 'Geometry changed; enable Recognize' unless @recognized_signature == geometry_signature(@main_model)
      if @recognized_revision && @recognized_revision != geometry_revision(@main_model)
        raise 'Geometry changed; enable Recognize'
      end
      @main_running = true
      launch_main_analysis
    end
    !!@main_running
  rescue => e
    main_fail(e.message, code: e.is_a?(RecognitionRequired) ? 'recognition_required' : nil)
  end

  def self.create_main_job
    parent = File.join(MPath::DATA, 'jobs')
    FileUtils.mkdir_p(parent)
    @main_dir = Dir.mktmpdir('main-analysis-', parent)
    File.write(File.join(@main_dir, 'request.json'), JSON.generate(@main_request), :encoding=>'UTF-8')
  end

  def self.launch_main_analysis
    raise 'Active model changed' unless Sketchup.active_model == @main_model
    raise 'Model context changed' unless (@context_revision || 0) == @main_context_revision
    raise 'No matching RDF snapshot' unless @recognized_model == @main_model && @recognized_files && !@recognized_files.empty?
    @main_signature = geometry_signature(@main_model)
    @main_geometry_revision = geometry_revision(@main_model)
    @main_request['model_snapshot'] = {'model_guid'=>@main_model.guid, 'geometry_signature'=>@main_signature, 'geometry_version'=>@main_geometry_revision}
    create_main_job unless @main_dir
    %w[epw_path csv_path sky_path].each do |key|
      next if key == 'sky_path' && !@main_request['require_radiation']
      source = @main_request['weather'][key]
      next unless source
      raise "Missing weather input: #{File.basename(source)}" unless File.file?(source)
      target = File.join(@main_dir, File.basename(source))
      FileUtils.cp(source, target)
      @main_request['weather'][key] = target
    end
    @main_request['rdf_paths'] = @recognized_files.each_with_index.map do |path, index|
      target = File.join(@main_dir, "model-#{index}.ttl")
      FileUtils.cp(path, target)
      target
    end
    @main_request['space_settings'] = $current_model.spaces.to_h do |space|
      baseline = (@baseline_settings || {})[space.id.to_s]
      values = baseline ? space.settings.reject { |key, value| baseline[key] == value } : space.settings
      Array(space.instance_variable_get(:@explicit_settings)).each { |key| values[key] = space.settings[key] }
      [space.id.to_s, {'values'=>values, 'source'=>baseline ? 'overrides' : 'legacy'}]
    end
    request_path = File.join(@main_dir, 'request.json')
    File.write(request_path, JSON.generate(@main_request), :encoding=>'UTF-8')
    main_status('model')
    started = MoosasUtils.exec_python_async('main_analysis.py', [
      'from skp.scripts.main_analysis import run_file',
      "run_file(#{request_path.to_json})"
    ], :workspace=>@main_dir) do |success|
      begin
        result_path = File.join(@main_dir, 'result.json')
        unless success && File.file?(result_path)
          error_path = File.join(@main_dir, 'error.json')
          raise(File.file?(error_path) ? JSON.parse(File.read(error_path, :encoding=>'UTF-8'))['message'] : 'Python failed; see stdout.log')
        end
        result = JSON.parse(File.read(result_path, :encoding=>'UTF-8'))
        raise 'Result request_id mismatch' unless result['request_id'] == @main_id
        unless Sketchup.active_model == @main_model && (@context_revision || 0) == @main_context_revision && geometry_signature(@main_model) == @main_signature && geometry_revision(@main_model) == @main_geometry_revision
          @main_running = false
          main_status('stale')
          next
        end
        @main_result = result
        @main_running = false
        MoosasMeta.get_and_set_dic('moosas', 'current', JSON.generate(result), false)
        history = MoosasMeta.get_and_set_dic('moosas', 'history', JSON.generate(result), true)
        main_emit('main_analysis_result', result)
        main_emit('update_analysis_history', history)
        main_status('complete')
      rescue => e
        main_fail(e.message)
      end
    end
    return main_fail('Could not start Python') unless started
    job_id = @main_id
    poll = nil
    poll = proc do
      if @main_running && @main_id == job_id
        path = File.join(@main_dir, 'progress.json')
        begin
          progress = JSON.parse(File.read(path, :encoding=>'UTF-8')) if File.file?(path)
          main_status(progress['stage']) if progress && progress['stage'] != 'complete'
        rescue JSON::ParserError, Errno::ENOENT
          # Atomic writer may be between updates.
        end
        UI.start_timer(0.5, false, &poll)
      end
    end
    UI.start_timer(0.5, false, &poll)
    true
  rescue => e
    main_fail(e.message)
  end
end
