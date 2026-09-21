# SketchUp adapter: context-bound SVG generation and transactional settings saves.
require 'json'
require 'digest'
require 'securerandom'
require 'tmpdir'
module MoosasModelPage
  def self.saving?
    !!@saving
  end

  def self.context
    record[:context] ||= SecureRandom.uuid
  end

  def self.editable_files
    valid_model!
    files = MoosasAnalysis.instance_variable_get(:@recognized_files)
    raise '当前识别结果没有 RDF / No recognized RDF' if !files || files.empty? || files.any? { |f| !File.file?(f) }
    root = File.join(MPath::DATA, 'models')
    unless files.all? { |f| File.expand_path(f).start_with?(File.expand_path(root) + File::SEPARATOR) }
      FileUtils.mkdir_p(root)
      dir = Dir.mktmpdir('model-', root)
      files = files.each_with_index.map { |f, i| dest = File.join(dir, "model-#{i}.ttl"); FileUtils.cp(f, dest); dest }
      MoosasAnalysis.instance_variable_set(:@recognized_files, files)
      MMR.instance_variable_set(:@last_rdf_files, files.dup)
    end
    files
  end

  def self.publish_svg
    return if busy?
    data = record
    token = context
    renderer_stamp = Digest::SHA256.file(File.join(MPath::SCRIPTS, 'render_space_svg.py')).hexdigest
    if data[:svg] && data[:svg_renderer_stamp] == renderer_stamp
      MoosasWebDialog.send('model_svg', data[:svg])
      return
    end
    return if data[:svg_loading]
    files = editable_files
    source_model, semantic = Sketchup.active_model, $current_model
    context_revision = MoosasAnalysis.instance_variable_get(:@context_revision)
    signature = MoosasAnalysis.geometry_signature(source_model)
    parent = File.join(MPath::DATA, 'jobs')
    FileUtils.mkdir_p(parent)
    dir = Dir.mktmpdir('space-svg-', parent)
    inputs = files.each_with_index.map { |f, i| dest = File.join(dir, "input-#{i}.ttl"); FileUtils.cp(f, dest); dest }
    path = File.join(dir, 'request.json')
    File.write(path, JSON.generate({'context'=>token, 'rdf_paths'=>inputs,
      'names'=>$current_model.spaces.to_h { |s| [s.id.to_s, s.settings['zone_name']] }}), encoding: 'UTF-8')
    data[:svg_loading] = true
    MoosasWebDialog.send('model_svg', {'context'=>token, 'loading'=>true})
    started = MoosasUtils.exec_python_async('space_svg.py', ['from skp.scripts.render_space_svg import render_request', "render_request(#{path.to_json})"], workspace: dir) do |success|
      data[:svg_loading] = false
      if Sketchup.active_model == source_model && $current_model == semantic && context == token && context_revision == MoosasAnalysis.instance_variable_get(:@context_revision) && signature == MoosasAnalysis.geometry_signature(source_model)
        begin
          raise '空间图生成失败，请查看任务日志 / SVG generation failed' unless success
          data[:svg] = JSON.parse(File.read(File.join(dir, 'result.json'), encoding: 'UTF-8'))
          data[:svg_renderer_stamp] = renderer_stamp
          MoosasWebDialog.send('model_svg', data[:svg])
        rescue => e
          MoosasWebDialog.send('model_svg', {'context'=>token, 'error'=>e.message})
        end
      end
    end
    unless started
      data[:svg_loading] = false
      raise '无法启动空间图生成 / Cannot start SVG job'
    end
  rescue => e
    MoosasWebDialog.send('model_svg', {'context'=>context, 'error'=>e.message})
  end

  # Restore unfinished file commits before accepting another edit. Existing jobs
  # and analysis snapshots are never candidates for a target, only recorded files.
  def self.recover_settings
    return if saving?
    Dir.glob(File.join(MPath::DATA, 'jobs', 'space-save-*', 'transaction.json')).each do |path|
      journal = JSON.parse(File.read(path, encoding: 'UTF-8'))
      next unless journal['state'] == 'committing'
      journal['changes'].each_with_index do |c, i|
        runtime = File.expand_path(MPath::DATA).tr('\\', '/').downcase + '/'
        raise 'Invalid recovery target' unless File.expand_path(c['target']).tr('\\', '/').downcase.start_with?(runtime)
        raise 'Invalid recovery backup' unless File.expand_path(c['backup']) == File.expand_path(File.join(File.dirname(path), "backup-#{i}"))
        FileUtils.cp(c['backup'], c['target']) if File.file?(c['backup'])
      end
      journal['state'] = 'rolled_back'
      File.write(path, JSON.generate(journal), encoding: 'UTF-8')
    end
  end

  def self.save_space(request)
    recover_settings
    raise '模型任务正在运行 / Model task is running' if busy?
    valid_model!
    raise '页面模型已变化，请刷新 / Model changed' unless request['context'] == context
    raise 'Geometry changed; recognize again' unless MoosasAnalysis.instance_variable_get(:@recognized_signature) == MoosasAnalysis.geometry_signature(Sketchup.active_model)
    space = $current_model.spaces.find { |s| s.id.to_s == request['space_id'] }
    raise '空间不存在 / Unknown space' unless space
    settings_path = MoosasUtils.settings_path
    raise '设置已变化，请刷新 / Settings changed' unless request['settings_version'] == MoosasUtils.settings_document['revision']
    source_model, semantic, token = Sketchup.active_model, $current_model, context
    context_revision = MoosasAnalysis.instance_variable_get(:@context_revision)
    signature = MoosasAnalysis.geometry_signature(source_model)
    files = editable_files
    parent = File.join(MPath::DATA, 'jobs')
    FileUtils.mkdir_p(parent)
    dir = Dir.mktmpdir('space-save-', parent)
    path = File.join(dir, 'request.json')
    payload = request.merge('rdf_paths'=>files, 'settings_path'=>settings_path, 'current_values'=>space.settings)
    File.write(path, JSON.generate(payload), encoding: 'UTF-8')
    @saving = true
    status
    started = MoosasUtils.exec_python_async('space_save.py', ['from skp.scripts.space_settings import prepare', "prepare(#{path.to_json})"], workspace: dir) do |success|
      begin
        unless success
          error = File.join(dir, 'stdout.log')
          detail = File.file?(error) ? File.readlines(error, encoding: 'UTF-8').last.to_s.strip : ''
          raise(detail.empty? ? '参数保存失败 / Save failed' : detail)
        end
        raise '模型已变化，修改未保存 / Model changed; edit not saved' unless Sketchup.active_model == source_model && $current_model == semantic && context == token && context_revision == MoosasAnalysis.instance_variable_get(:@context_revision) && signature == MoosasAnalysis.geometry_signature(source_model)
        result = JSON.parse(File.read(File.join(dir, 'result.json'), encoding: 'UTF-8'))
        raise 'Request mismatch' unless result['request_id'] == request['request_id']
        old_settings, old_explicit, old_graph = space.settings.dup, space.instance_variable_get(:@explicit_settings), $ontologies
        changes = result['changes']
        changes.each_with_index do |c, i|
          allowed = (files + [settings_path]).map { |f| File.expand_path(f).tr('\\', '/').downcase }
          raise 'Unexpected save target' unless allowed.include?(File.expand_path(c['target']).tr('\\', '/').downcase)
          digest = File.file?(c['target']) ? Digest::SHA256.file(c['target']).hexdigest : nil
          raise '文件已被修改 / File changed during save' unless digest == c['sha256']
          c['backup'] = File.join(dir, "backup-#{i}")
          FileUtils.cp(c['target'], c['backup'])
        end
        journal_path = File.join(dir, 'transaction.json')
        journal = {'state'=>'committing', 'changes'=>changes}
        File.write(journal_path, JSON.generate(journal), encoding: 'UTF-8')
        begin
          changes.each do |c|
            staged = c['target'] + '.pending'
            FileUtils.cp(c['prepared'], staged)
            File.rename(staged, c['target'])
          end
          graph = RDF::Graph.new
          files.each { |f| MoosasRdf.graph_from_turtle(f).each_statement { |st| graph << st } }
          space.settings[result['field']] = result['value']
          space.instance_variable_set(:@explicit_settings, (Array(old_explicit) + [result['field']]).uniq)
          $ontologies = graph
          journal['state'] = 'committed'
          File.write(journal_path, JSON.generate(journal), encoding: 'UTF-8')
        rescue
          changes.each { |c| FileUtils.cp(c['backup'], c['target']) }
          space.settings.replace(old_settings)
          space.instance_variable_set(:@explicit_settings, old_explicit)
          $ontologies = old_graph
          journal['state'] = 'rolled_back'
          File.write(journal_path, JSON.generate(journal), encoding: 'UTF-8')
          raise
        end
        MoosasWebDialog.send('space_parameter_result', result.reject { |k, _| k == 'changes' }.merge('context'=>token))
      rescue => e
        MoosasWebDialog.send('space_parameter_error', request.merge('message'=>e.message))
      ensure
        @saving = false
        publish
      end
    end
    unless started
      @saving = false
      raise '无法启动参数保存 / Cannot start save job'
    end
    true
  rescue => e
    MoosasWebDialog.send('space_parameter_error', request.merge('message'=>e.message))
    status
    false
  end

  # Drafts deliberately touch only the settings JSON. They never load Python,
  # mutate RDF or rebuild the Ruby semantic graph.
  def self.save_drafts(request)
    raise '页面模型已变化，请刷新 / Model changed' unless request['context'] == context
    path = MoosasUtils.settings_path
    data = MoosasUtils.settings_document
    data['schema_version'] = [data['schema_version'].to_i, 3].max
    data['drafts'] ||= {}
    data['drafts'] = request['drafts'].is_a?(Hash) ? request['drafts'] : {}
    data['draft_revision'] = data.fetch('draft_revision', 0).to_i + 1
    temporary = path + '.draft.tmp'
    File.write(temporary, JSON.generate(data), encoding: 'UTF-8')
    File.rename(temporary, path)
    MoosasWebDialog.send('space_drafts_result', {'context'=>context, 'draft_revision'=>data['draft_revision']})
    true
  rescue => e
    MoosasWebDialog.send('space_drafts_error', {'context'=>context, 'message'=>e.message})
    false
  end

  def self.save_batch(request)
    recover_settings
    raise '模型任务正在运行 / Model task is running' if busy?
    valid_model!
    raise '页面模型已变化，请刷新 / Model changed' unless request['context'] == context
    raise 'Geometry changed; recognize again' unless MoosasAnalysis.instance_variable_get(:@recognized_signature) == MoosasAnalysis.geometry_signature(Sketchup.active_model)
    settings_path = MoosasUtils.settings_path
    raise '设置已变化，请刷新 / Settings changed' unless request['settings_version'] == MoosasUtils.settings_document['revision']
    source_model, semantic, token = Sketchup.active_model, $current_model, context
    signature = MoosasAnalysis.geometry_signature(source_model); files = editable_files
    dir = Dir.mktmpdir('space-save-', File.join(MPath::DATA, 'jobs')); path = File.join(dir, 'request.json')
    File.write(path, JSON.generate(request.merge('rdf_paths'=>files, 'settings_path'=>settings_path)), encoding: 'UTF-8')
    @saving = true; status
    started = MoosasUtils.exec_python_async('space_save_batch.py', ['from skp.scripts.space_settings import prepare_batch', "prepare_batch(#{path.to_json})"], workspace: dir) do |success|
      begin
        raise '参数保存失败 / Save failed' unless success
        raise '模型已变化，修改未保存 / Model changed; edit not saved' unless Sketchup.active_model == source_model && $current_model == semantic && context == token && signature == MoosasAnalysis.geometry_signature(source_model)
        result = JSON.parse(File.read(File.join(dir, 'result.json'), encoding: 'UTF-8'))
        raise 'Request mismatch' unless result['request_id'] == request['request_id']
        changes = result['changes']; allowed = (files + [settings_path]).map { |f| File.expand_path(f).tr('\\', '/').downcase }
        changes.each_with_index do |c, i|
          raise 'Unexpected save target' unless allowed.include?(File.expand_path(c['target']).tr('\\', '/').downcase)
          raise '文件已被修改 / File changed during save' unless (File.file?(c['target']) ? Digest::SHA256.file(c['target']).hexdigest : nil) == c['sha256']
          c['backup'] = File.join(dir, "backup-#{i}"); FileUtils.cp(c['target'], c['backup']) if File.file?(c['target'])
        end
        journal_path = File.join(dir, 'transaction.json'); File.write(journal_path, JSON.generate({'state'=>'committing', 'changes'=>changes}), encoding: 'UTF-8')
        begin
          changes.each { |c| staged = c['target'] + '.pending'; FileUtils.cp(c['prepared'], staged); File.rename(staged, c['target']) }
          result['items'].each do |item|
            if item['type'] == 'space'
              space = $current_model.spaces.find { |s| s.id.to_s == item['id'].to_s }; next unless space
              space.settings.merge!(item['values']); space.instance_variable_set(:@explicit_settings, (Array(space.instance_variable_get(:@explicit_settings)) + item['values'].keys).uniq)
            else
              element = $current_model.get_all_face.find { |f| f.respond_to?(:uid) && f.uid.to_s == item['id'].to_s }
              next unless element
              element.settings ||= {}
              element.settings.merge!(item['values'])
              element.settings['u'] = item['values']['u_value'] if item['values'].key?('u_value')
              element.instance_variable_set(:@explicit_settings, (Array(element.instance_variable_get(:@explicit_settings)) + item['values'].keys).uniq)
            end
          end
          File.write(journal_path, JSON.generate({'state'=>'committed', 'changes'=>changes}), encoding: 'UTF-8')
        rescue
          changes.each { |c| FileUtils.cp(c['backup'], c['target']) if File.file?(c['backup']) }; raise
        end
        MoosasWebDialog.send('space_batch_result', result.reject { |k, _| k == 'changes' }.merge('context'=>token))
      rescue => e
        MoosasWebDialog.send('space_batch_error', request.merge('message'=>e.message))
      ensure
        @saving = false; publish
      end
    end
    raise '无法启动参数保存 / Cannot start save job' unless started
    true
  rescue => e
    @saving = false; MoosasWebDialog.send('space_batch_error', request.merge('message'=>e.message)); status; false
  end
end
