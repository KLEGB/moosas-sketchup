module RDF
  module VERSION
    # The gem is vendored into one shared directory, so its original gem-root
    # VERSION file is intentionally not used at runtime.
    MAJOR, MINOR, TINY, EXTRA = '3', '2', '12', nil
    STRING = [MAJOR, MINOR, TINY, EXTRA].compact.join('.').freeze

    ##
    # @return [String]
    def self.to_s() STRING end

    ##
    # @return [String]
    def self.to_str() STRING end

    ##
    # @return [Array(String, String, String, String)]
    def self.to_a() [MAJOR, MINOR, TINY, EXTRA].compact end
  end
end
