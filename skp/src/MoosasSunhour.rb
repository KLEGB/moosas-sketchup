class MoosasSunHour
  Ver = '0.7.0'
  DEFAULT_PARAMETERS = 'default 1 21 12 21 12 1 1 7 00 18 00 t t t t t t t 1 f f'

  # The shared adapter runs the ray workload asynchronously in Python. Ruby
  # keeps ownership of selected grids and SketchUp result visualisation.
  def self.sunhour_analyse_grids(parameters = DEFAULT_PARAMETERS)
    MoosasSurfaceAnalysis.start('sunhour', parameters)
  end
end
