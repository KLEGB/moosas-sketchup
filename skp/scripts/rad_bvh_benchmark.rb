require 'json'
require 'fileutils'
require 'digest'

# Bridge-only diagnostics. Export/sampling never change model selection/entities.
module RadBVHBenchmark
  def self.start_smoke(mode, directory)
    model = Sketchup.active_model
    raise 'No selected analysis grid' if MoosasSurfaceAnalysis.selected_grids(model).empty?
    raise 'Analysis already running' if MoosasSurfaceAnalysis.running? || MMR.transform_running?
    FileUtils.mkdir_p(directory)
    before = {selection: model.selection.map(&:persistent_id), entities: model.entities.length,
              grids: MoosasSurfaceAnalysis.serialize_grids(MoosasSurfaceAnalysis.selected_grids(model))}
    File.write(File.join(directory, mode + '.before.json'), JSON.pretty_generate(before), encoding: 'UTF-8')
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    started = mode == 'sunhour' ? MoosasSunHour.sunhour_analyse_grids : MoosasRadiance.calculate_radiance
    raise 'Smoke analysis did not start' unless started
    timer = UI.start_timer(0.1, true) do
      next if MoosasSurfaceAnalysis.running?
      UI.stop_timer(timer)
      result = MoosasSurfaceAnalysis.last_result
      summary = {success: !!result, elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC)-started_at,
                 selection_before: before[:selection], selection_after: model.selection.map(&:persistent_id),
                 entities_before: before[:entities], entities_after: model.entities.length, result: result}
      File.write(File.join(directory, mode + '.after.json'), JSON.pretty_generate(summary), encoding: 'UTF-8')
    end
    {started: true, analysis: mode}
  end

  def self.export(directory, seed = 4217)
    raise 'Analysis already running' if MoosasSurfaceAnalysis.running? || MMR.transform_running?
    model = Sketchup.active_model
    FileUtils.mkdir_p(directory)
    scene = File.join(directory, 'scene.geo')
    MoosasSurfaceAnalysis.export_scene(model, scene)
    candidates = []
    MoosasSurfaceAnalysis.walk_scene(model.entities) do |face, path|
      next unless MMR.user_visible?(face) && path.all? { |e| MMR.user_visible?(e) }
      tr = path.inject(Geom::Transformation.new) { |total, e| total * e.transformation }
      normal = face.normal.transform(tr)
      next if normal.length.zero?
      normal.length = 1
      mesh = face.mesh(0)
      triangles = mesh.polygons.filter_map do |polygon|
        local = polygon.map { |index| mesh.point_at(index.abs) }
        next unless local.length == 3
        world = local.map { |p| (tr * p).to_a.map { |v| v * 0.0254 } }
        next unless MMRGeoExport.rad_projected_triangle?(world, normal)
        area = Math.sqrt(MMRGeoExport.dot(MMRGeoExport.cross(MMRGeoExport.subtract(world[1],world[0]),MMRGeoExport.subtract(world[2],world[0])), MMRGeoExport.cross(MMRGeoExport.subtract(world[1],world[0]),MMRGeoExport.subtract(world[2],world[0])))) * 0.5
        next unless area > 1.0e-12
        {points: world, area: area}
      end
      next if triangles.empty?
      candidates << {id: (path + [face]).map(&:persistent_id).join('/'), normal: normal.to_a, triangles: triangles}
    end
    raise "Only #{candidates.length} valid faces; need 100" if candidates.length < 100
    random = Random.new(seed)
    selected = candidates.sort_by { |f| f[:id] }.shuffle(random: random).first(100)
    grids = selected.map do |f|
      total = f[:triangles].sum { |t| t[:area] }
      points = Array.new(25) do
        target = random.rand * total
        triangle = f[:triangles].find { |t| target -= t[:area]; target < 0 } || f[:triangles].last
        a,b,c = triangle[:points]
        s = Math.sqrt(random.rand); q = random.rand
        (0..2).map { |axis| (1-s)*a[axis] + s*(1-q)*b[axis] + s*q*c[axis] + 0.1*f[:normal][axis] }
      end
      {id: f[:id], normal: f[:normal], nodes: [points]}
    end
    sky = File.join(MPath::SKY, "cumsky_#{MoosasWeather.station_id}.csv")
    frozen_sky = File.join(directory, 'cumulative_sky.csv')
    FileUtils.cp(sky, frozen_sky)
    request = {schema_version: 1, job_id: 'rad-bvh-100-faces', scene_path: scene, location: MoosasSurfaceAnalysis.location_payload,
               grids: grids, cumulative_sky_path: frozen_sky, sunhour_parameters: MoosasSunHour::DEFAULT_PARAMETERS}
    %w[sunhour radiation].each do |mode|
      File.write(File.join(directory, mode + '.request.json'), JSON.pretty_generate(request.merge(analysis: mode)), encoding: 'UTF-8')
    end
    manifest = {seed: seed, visible_valid_faces: candidates.length, sampled_faces: grids.length, points: grids.sum { |g| g[:nodes][0].length },
                scene_sha256: Digest::SHA256.file(scene).hexdigest, sky_sha256: Digest::SHA256.file(frozen_sky).hexdigest,
                selection: model.selection.map(&:persistent_id), entity_count: model.entities.length,
                selected_faces: selected.map { |f| {id: f[:id], normal: f[:normal], area: f[:triangles].sum { |t| t[:area] }} }}
    File.write(File.join(directory, 'manifest.json'), JSON.pretty_generate(manifest), encoding: 'UTF-8')
    manifest.reject { |key,_| key == :selected_faces }
  end

  def self.edge_distance(face, transform, point)
    face.edges.map do |edge|
      a,b = edge.vertices.map { |v| transform * v.position }
      ab = b - a
      fraction = [[(point-a).dot(ab) / ab.dot(ab), 0.0].max, 1.0].min
      nearest = Geom::Point3d.new((0..2).map { |axis| a[axis]+fraction*ab[axis] })
      point.distance(nearest)*0.0254
    end.min
  end

  def self.native_compare(input, output)
    data = JSON.parse(File.read(input, encoding: 'UTF-8'))
    model = Sketchup.active_model
    faces = {}
    MoosasSurfaceAnalysis.walk_scene(model.entities) do |face,path|
      transform = path.inject(Geom::Transformation.new) { |a,e| a * e.transformation }
      faces[(path+[face]).map(&:persistent_id).join('/')] = [face,transform]
    end
    results = data.map do |sample|
      original = Geom::Point3d.new(sample.fetch('origin').map { |v| v / 0.0254 })
      direction = Geom::Vector3d.new(sample.fetch('direction')); direction.normalize!
      origin = original
      accepted = nil
      100.times do
        hit = model.raytest([origin, direction], true)
        break unless hit
        point, path = hit
        ignored = path.any? { |e| e.attribute_dictionary('grid', false) || e.get_attribute('MoosasSurfaceAnalysis', 'visualization', false) }
        if !ignored && original.distance(point) * 0.0254 > 0.01
          face = path.last
          transform = path[0...-1].inject(Geom::Transformation.new) { |a,e| a * e.transformation }
          accepted = {point: point.to_a.map { |v| v * 0.0254 }, path: path.map(&:persistent_id), type: face.typename,
                      boundary_distance: face.is_a?(Sketchup::Face) ? edge_distance(face, transform, point) : nil}
          break
        end
        origin = point.offset(direction, 0.00001 / 0.0254)
      end
      diagnostic = nil
      if sample['engine'] && sample['engine_source'] && faces[sample['engine_source']]
        face, transform = faces[sample['engine_source']]
        point = Geom::Point3d.new(sample['engine'].map { |v| v / 0.0254 })
        local = (transform.inverse * point).project_to_plane(face.plane)
        diagnostic = {classification:face.classify_point(local), boundary_distance:edge_distance(face,transform,point), source:sample['engine_source']}
      end
      {index: sample.fetch('index'), native: accepted, engine_face:diagnostic}
    end
    File.write(output, JSON.pretty_generate(results), encoding: 'UTF-8')
    {count: results.length, hits: results.count { |r| r[:native] }, selection: model.selection.map(&:persistent_id)}
  end
end
