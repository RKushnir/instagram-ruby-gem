require 'faraday'
require 'json'

module Faraday
  module Response
    class ParseJson < Faraday::Response::Middleware
      WHITESPACE_REGEX = /\A^\s*$\z/

      def parse(body)
        case body
        when WHITESPACE_REGEX, nil
          nil
        else
          JSON.parse(body, :symbolize_names => true)
        end
      end

      def on_complete(response)
        response.body = parse(response.body) if respond_to?(:parse) && !unparsable_status_codes.include?(response.status)
      end

      def unparsable_status_codes
        [204, 301, 302, 304]
      end
    end
  end
end

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
