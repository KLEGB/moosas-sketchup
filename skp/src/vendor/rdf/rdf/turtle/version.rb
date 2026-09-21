module RDF::Turtle::VERSION
  # The gem is vendored into one shared directory, so its original gem-root
  # VERSION file is intentionally not used at runtime.
  MAJOR, MINOR, TINY, EXTRA = '3', '2', '1', nil

  STRING = [MAJOR, MINOR, TINY, EXTRA].compact.join('.')

  ##
  # @return [String]
  def self.to_s()   STRING end

  ##
  # @return [String]
  def self.to_str() STRING end

  ##
  # @return [Array(Integer, Integer, Integer)]
  def self.to_a() STRING.split(".") end
end
