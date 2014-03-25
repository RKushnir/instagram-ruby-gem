require 'faraday'

module FaradayMiddleware
  # Internal: The base class for middleware that parses responses.
  class ResponseMiddleware < Faraday::Middleware
    CONTENT_TYPE = 'Content-Type'.freeze

    class << self
      attr_accessor :parser
    end

    # Store a Proc that receives the body and returns the parsed result.
    def self.define_parser(parser = nil)
      @parser = parser || Proc.new
    end

    def self.inherited(subclass)
      super
      subclass.load_error = self.load_error if subclass.respond_to? :load_error=
      subclass.parser = self.parser
    end

    def initialize(app = nil, options = {})
      super(app)
      @options = options
      @content_types = Array(options[:content_type])
    end

    def call(environment)
      @app.call(environment).on_complete do |env|
        if process_response_type?(response_type(env)) and parse_response?(env)
          process_response(env)
        end
      end
    end

    def process_response(env)
      env[:raw_body] = env[:body] if preserve_raw?(env)
      env[:body] = parse(env[:body])
    end

    # Parse the response body.
    #
    # Instead of overriding this method, consider using `define_parser`.
    def parse(body)
      if self.class.parser
        begin
          self.class.parser.call(body)
        rescue StandardError, SyntaxError => err
          raise err if err.is_a? SyntaxError and err.class.name != 'Psych::SyntaxError'
          raise Faraday::Error::ParsingError, err
        end
      else
        body
      end
    end

    def response_type(env)
      type = env[:response_headers][CONTENT_TYPE].to_s
      type = type.split(';', 2).first if type.index(';')
      type
    end

    def process_response_type?(type)
      @content_types.empty? or @content_types.any? { |pattern|
        pattern.is_a?(Regexp) ? type =~ pattern : type == pattern
      }
    end

    def parse_response?(env)
      env[:body].respond_to? :to_str
    end

    def preserve_raw?(env)
      env[:request].fetch(:preserve_raw, @options[:preserve_raw])
    end
  end
end


module FaradayMiddleware
  # Public: Parse response bodies as JSON.
  class ParseJson < ResponseMiddleware
    dependency do
      require 'json' unless defined?(::JSON)
    end

    define_parser do |body|
      ::JSON.parse body unless body.strip.empty?
    end

    # Public: Override the content-type of the response with "application/json"
    # if the response body looks like it might be JSON, i.e. starts with an
    # open bracket.
    #
    # This is to fix responses from certain API providers that insist on serving
    # JSON with wrong MIME-types such as "text/javascript".
    class MimeTypeFix < ResponseMiddleware
      MIME_TYPE = 'application/json'.freeze

      def process_response(env)
        old_type = env[:response_headers][CONTENT_TYPE].to_s
        new_type = MIME_TYPE.dup
        new_type << ';' << old_type.split(';', 2).last if old_type.index(';')
        env[:response_headers][CONTENT_TYPE] = new_type
      end

      BRACKETS = %w- [ { -
      WHITESPACE = [ " ", "\n", "\r", "\t" ]

      def parse_response?(env)
        super and BRACKETS.include? first_char(env[:body])
      end

      def first_char(body)
        idx = -1
        begin
          char = body[idx += 1]
          char = char.chr if char
        end while char and WHITESPACE.include? char
        char
      end
    end
  end
end

# deprecated alias
Faraday::Response::ParseJson = FaradayMiddleware::ParseJson

module FaradayMiddleware
  # Public: Converts parsed response bodies to a Hashie::Mash if they were of
  # Hash or Array type.
  class Mashify < Faraday::Response::Middleware
    attr_accessor :mash_class

    class << self
      attr_accessor :mash_class
    end

    dependency do
      require 'hashie/mash'
      self.mash_class = ::Hashie::Mash
    end

    def initialize(app = nil, options = {})
      super(app)
      self.mash_class = options[:mash_class] || self.class.mash_class
    end

    def parse(body)
      case body
      when Hash
        mash_class.new(body)
      when Array
        body.map { |item| parse(item) }
      else
        body
      end
    end
  end
end

# deprecated alias
Faraday::Response::Mashify = FaradayMiddleware::Mashify

Dir[File.expand_path('../../faraday/*.rb', __FILE__)].each{|f| require f}

module Instagram
  # @private
  module Connection
    private

    def connection(raw=false)
      options = {
        :headers => {'Accept' => "application/#{format}; charset=utf-8", 'User-Agent' => user_agent},
        :proxy => proxy,
        :url => endpoint,
      }

      Faraday::Connection.new(options) do |connection|
        connection.use FaradayMiddleware::InstagramOAuth2, client_id, access_token
        connection.use Faraday::Request::UrlEncoded
        connection.use FaradayMiddleware::Mashify unless raw
        unless raw
          case format.to_s.downcase
          when 'json' then connection.use Faraday::Response::ParseJson
          end
        end
        connection.use FaradayMiddleware::RaiseHttpException
        connection.adapter(adapter)
      end
    end
  end
end
