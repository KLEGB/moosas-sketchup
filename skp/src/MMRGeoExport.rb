# GEO accepts simple polygon rings, whereas a SketchUp Loop may revisit a
# vertex/edge (a slit connecting an inner boundary to the exterior).
# This module only normalizes export topology; it never edits SketchUp faces.
module MMRGeoExport
  EPSILON = 1.0e-9

  def self.subtract(a, b)
    a.zip(b).map { |x, y| x - y }
  end

  def self.dot(a, b)
    a.zip(b).sum { |x, y| x * y }
  end

  def self.cross(a, b)
    [a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]]
  end

  def self.unit(vector)
    length = Math.sqrt(dot(vector, vector))
    return nil if length <= EPSILON
    vector.map { |v| v / length }
  end

  def self.frame(points)
    return nil if points.length < 3
    origin = points.first
    vectors = points.map { |p| subtract(p, origin) }
    u = unit(vectors.max_by { |v| dot(v, v) })
    return nil unless u
    n = unit(vectors.map { |v| cross(u, v) }.max_by { |v| dot(v, v) })
    return nil unless n
    [origin, u, cross(n, u)]
  end

  def self.project(points, basis)
    origin, u, v = basis
    points.map { |p| delta = subtract(p, origin); [dot(delta, u), dot(delta, v)] }
  end

  def self.rounded(points)
    points.map { |p| p.map { |v| v.round(3) } }
  end

  # Match RAD's projection and zero-area validation after GEO serialization.
  # A triangle can acquire a spurious 3D area through coordinate rounding while
  # remaining degenerate in the plane of its supplied face normal.
  def self.rad_projected_triangle?(points, normal)
    n = unit(normal.to_a)
    return false unless n
    projected = if n[2].abs > 1.0e-6
                  rounded(points).map { |p| p.first(2) }
                else
                  u = unit(cross([0.0, 0.0, 1.0], n))
                  v = unit(cross(n, u))
                  rounded(points).map { |p| [dot(p, u), dot(p, v)] }
                end
    area(projected).abs * 2.0 > 1.0e-12
  end

  def self.area(ring)
    ring.each_index.sum { |i| a = ring[i]; b = ring[(i+1) % ring.length]; a[0]*b[1] - b[0]*a[1] } / 2.0
  end

  def self.turn(a, b, c)
    (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0])
  end

  def self.on_segment?(p, a, b)
    turn(a, b, p).abs <= EPSILON && (0..1).all? do |i|
      p[i] >= [a[i], b[i]].min - EPSILON && p[i] <= [a[i], b[i]].max + EPSILON
    end
  end

  def self.crossing?(a, b, c, d)
    ab_c, ab_d, cd_a, cd_b = turn(a,b,c), turn(a,b,d), turn(c,d,a), turn(c,d,b)
    ((ab_c > EPSILON && ab_d < -EPSILON) || (ab_c < -EPSILON && ab_d > EPSILON)) &&
      ((cd_a > EPSILON && cd_b < -EPSILON) || (cd_a < -EPSILON && cd_b > EPSILON))
  end

  def self.intersect?(a, b, c, d)
    crossing?(a,b,c,d) || on_segment?(a,c,d) || on_segment?(b,c,d) || on_segment?(c,a,b) || on_segment?(d,a,b)
  end

  def self.simple?(ring)
    count = ring.length
    return false if count < 3 || area(ring).abs <= EPSILON
    count.times do |i|
      a, b, c = ring[i], ring[(i+1) % count], ring[(i+2) % count]
      return false if dot(subtract(a,b), subtract(a,b)) <= EPSILON**2
      # Adjacent collinear edges must not double back over each other.
      return false if turn(a,b,c).abs <= EPSILON && dot(subtract(a,b), subtract(c,b)) > EPSILON
      ((i+1)...count).each do |j|
        next if j == i+1 || (i == 0 && j == count-1)
        return false if intersect?(a,b,ring[j],ring[(j+1) % count])
      end
    end
    true
  end

  def self.inside?(point, ring)
    inside = false
    ring.each_index do |i|
      a, b = ring[i], ring[(i+1) % ring.length]
      return true if on_segment?(point, a, b)
      if (a[1] > point[1]) != (b[1] > point[1])
        x = a[0] + (point[1]-a[1])*(b[0]-a[0])/(b[1]-a[1])
        inside = !inside if x > point[0]
      end
    end
    inside
  end

  def self.contains_ring?(outer, inner)
    return false unless inner.all? { |p| inside?(p, outer) }
    inner.each_index.all? do |i|
      a, b = inner[i], inner[(i+1) % inner.length]
      inside?([(a[0]+b[0])/2, (a[1]+b[1])/2], outer) && outer.each_index.none? do |j|
        crossing?(a,b,outer[j],outer[(j+1) % outer.length])
      end
    end
  end

  # Split a closed walk at repeated vertex identities. Two-vertex cycles are
  # the traversed-and-retraced bridge, not polygon boundaries.
  def self.cycles(keys, points)
    stack_keys, stack_points, rings = [], [], []
    (keys + [keys.first]).zip(points + [points.first]).each do |key, point|
      index = stack_keys.index(key)
      if index
        ring = stack_points[index..-1]
        rings << ring if ring.length >= 3
        stack_keys = stack_keys[0..index]
        stack_points = stack_points[0..index]
      else
        stack_keys << key
        stack_points << point
      end
    end
    rings
  end

  # loops: outer first, each {keys: SketchUp vertex IDs, points: world metres}.
  # The fallback block supplies triangles from Face#mesh only if needed.
  def self.normalize(source_id, loops)
    outer = loops.first.fetch(:points)
    basis = frame(outer)
    if basis
      # Preserve the existing path for geometrically simple faces, including
      # tiny features affected by the exporter's longstanding 3-decimal format.
      # Rounded-coordinate validation below applies to our repaired output.
      projected = loops.map { |loop| project(loop[:points], basis) }
      normal = loops.each_with_index.all? do |loop, i|
        loop[:keys].uniq.length == loop[:keys].length && simple?(projected[i])
      end
      if normal
        return {mode: 'unchanged', records: [{id: source_id, outer: outer, holes: loops.drop(1).map { |l| l[:points] }}]}
      end

      rings = cycles(loops.first[:keys], outer)
      uv = rings.map { |ring| project(rounded(ring), basis) }
      if !rings.empty? && uv.all? { |ring| simple?(ring) }
        index = uv.each_index.max_by { |i| area(uv[i]).abs }
        if uv.each_with_index.all? { |ring, i| i == index || contains_ring?(uv[index], ring) }
          return {mode: 'outer_only', records: [{id: source_id, outer: rings[index], holes: []}]}
        end
      end
    end

    triangles = yield
    raise "No exportable mesh for #{source_id}" if triangles.empty?
    rejected = []
    records = triangles.each_with_index.filter_map do |triangle, index|
      triangle_basis = frame(triangle)
      unless triangle.length == 3 && triangle_basis && simple?(project(rounded(triangle), triangle_basis))
        # SketchUp meshes can contain sliver triangles that collapse in GEO's
        # millimetre coordinate format. Drop only those unrepresentable pieces;
        # fail below if the face has no remaining exportable area.
        rejected << {source_id: source_id, triangle: index + 1, reason: 'degenerate_after_rounding'}
        next
      end
      {id: "#{source_id}__tri_#{format('%04d', index + 1)}", outer: triangle, holes: []}
    end
    raise "No exportable mesh triangles for #{source_id} after millimetre rounding" if records.empty?
    {mode: 'triangles', records: records, rejected: rejected}
  end

  def self.serialize(record, category, normal)
    lines = ["f,#{category},#{record[:id]}", "fn,#{normal.to_a.join(',')}"]
    rounded(record[:outer]).each { |point| lines << "fv,#{point.join(',')}" }
    record[:holes].each_with_index do |hole, i|
      rounded(hole).each { |point| lines << "fh,#{i},#{point.join(',')}" }
    end
    (lines + [';']).join("\n") + "\n"
  end
end
