# frozen_string_literal: true

# IDF export orchestration. Geometry/model conversion is intentionally kept in
# MoosasPy so this module remains a thin SketchUp UI and async-process adapter.
module MoosasIDF
  require 'fileutils'
  require 'json'
  @export_running = false

  def self.export_running?
    @export_running == true
  end

  # Backwards-compatible name used by older callers and toolbar definitions.
  def self.run_idf
    self.export_async
  end

  def self.export_async(output_dir = nil)
    return false if defined?(MoosasModelPage) && MoosasModelPage.saving?
    if defined?(MoosasModelPage) && MoosasModelPage.drafts_block_compute?
      UI.messagebox('存在未保存的参数修改，请点击 Save 后再导出；再次导出将使用已保存版本。')
      return false
    end
    return false if defined?(MoosasAnalysis) && MoosasAnalysis.main_analysis_running?
    return false if defined?(MoosasDaylight) && MoosasDaylight.running?
    return false if self.export_running?

    output_dir ||= self.choose_output_directory
    if output_dir.nil? || output_dir.empty?
      p "IDF export cancelled: no output directory selected."
      return false
    end

    @export_running = true
    started = MMR.update_model_async do |recognized|
      if recognized
        self.export_current_model_async(output_dir)
      else
        @export_running = false
        p "IDF export cancelled: model recognition failed."
      end
    end

    unless started
      @export_running = false
      p "IDF export is unavailable while model transformation is running."
      return false
    end
    true
  rescue Exception => e
    @export_running = false
    MoosasUtils.rescue_log(e) if defined?(MoosasUtils)
    raise
  end

  def self.choose_output_directory
    default_dir = File.join(MPath::DATA, "energy", "idf")
    FileUtils.mkdir_p(default_dir)
    UI.select_directory(
      :title => "Select IDF export directory",
      :directory => default_dir
    )
  end

  def self.export_current_model_async(output_dir)
    rdf_files = MMR.rdf_files
    if rdf_files.empty?
      @export_running = false
      raise "No transformed RDF files are available for IDF export."
    end

    output_dir = File.expand_path(output_dir)
    template_path = File.join(MPath::DB, "in.idf")
    code = [
      "from skp.scripts.idf_export import export_idf_batch",
      "export_idf_batch(#{rdf_files.to_json}, #{output_dir.to_json}, #{template_path.to_json})"
    ]

    started = MoosasUtils.exec_python_async("export_idf.py", code, console: true) do |success|
      @export_running = false
      if success
        p "IDF export complete: #{output_dir}"
      else
        p "IDF export failed. Check the latest export_idf job under: #{File.join(MPath::DATA, 'jobs')}"
      end
    end

    unless started
      @export_running = false
      raise "Could not start Python IDF export."
    end
    true
  rescue Exception => e
    @export_running = false
    MoosasUtils.rescue_log(e) if defined?(MoosasUtils)
    raise
  end
end
