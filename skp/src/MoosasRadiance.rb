class MoosasRadiance
  Ver = '0.7.0'

  # Annual cumulative radiation is submitted to the shared asynchronous Python
  # adapter; Ruby only coordinates SketchUp grids and their visual result.
  def self.calculate_radiance
    MoosasSurfaceAnalysis.start('radiation')
  end
end
