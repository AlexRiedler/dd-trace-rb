require 'json'

require 'ddtrace/transport/traces'
require 'ddtrace/transport/http/response'
require 'ddtrace/transport/http/api/endpoint'

module Datadog
  module Transport
    module HTTP
      # HTTP transport behavior for traces
      module Traces
        # Response from HTTP transport for traces
        class Response
          include HTTP::Response
          include Transport::Traces::Response

          def initialize(http_response, options = {})
            super(http_response)
            @service_rates = options.fetch(:service_rates, nil)
            @trace_count = options.fetch(:trace_count, 0)
          end
        end

        # Extensions for HTTP client
        module Client
          def send_traces(traces)
            encoder = current_api.spec.traces.encoder
            encoder.encode_traces(traces) do |encoded_traces, trace_count|
              # Send traces and get response
              send_data(encoded_traces, trace_count)
            end
          rescue UnsupportedVersionError => _
            # Downgrade preformed, restart method as the encoder might have changed
            return send_traces(traces)
          end

          def send_data(data, trace_count)
            request = Transport::Traces::Request.new(data, trace_count)

            send_request(request) do |api, env|
              api.send_traces(env)
            end
          end
        end

        module API
          # Extensions for HTTP API Spec
          module Spec
            attr_reader :traces

            def traces=(endpoint)
              @traces = endpoint
            end

            def send_traces(env, &block)
              raise NoTraceEndpointDefinedError, self if traces.nil?
              traces.call(env, &block)
            end

            # Raised when traces sent but no traces endpoint is defined
            class NoTraceEndpointDefinedError < StandardError
              attr_reader :spec

              def initialize(spec)
                @spec = spec
              end

              def message
                'No trace endpoint is defined for API specification!'
              end
            end
          end

          # Extensions for HTTP API Instance
          module Instance
            def send_traces(env)
              raise TracesNotSupportedError, spec unless spec.is_a?(Traces::API::Spec)

              spec.send_traces(env) do |request_env|
                call(request_env)
              end
            end

            # Raised when traces sent to API that does not support traces
            class TracesNotSupportedError < StandardError
              attr_reader :spec

              def initialize(spec)
                @spec = spec
              end

              def message
                'Traces not supported for this API!'
              end
            end
          end

          # Endpoint for submitting trace data
          class Endpoint < HTTP::API::Endpoint
            HEADER_CONTENT_TYPE = 'Content-Type'.freeze
            HEADER_TRACE_COUNT = 'X-Datadog-Trace-Count'.freeze
            SERVICE_RATE_KEY = 'rate_by_service'.freeze

            attr_reader \
              :encoder

            def initialize(path, encoder, options = {})
              super(:post, path)
              @encoder = encoder
              @service_rates = options.fetch(:service_rates, false)
            end

            def service_rates?
              @service_rates == true
            end

            def call(env, &block)
              encoder.encode_traces(env.request.parcel.data) do |encoded_data, count|
                # Ensure no data is leaked between each request.
                # We have perform this copy before we start modifying headers and body.
                new_env = env.dup

                process_batch(new_env, encoded_data, count) { |e| super(e, &block) }
              end
            end

            private

            def process_batch(env, encoded_data, count)
              # Add trace count header
              env.headers[HEADER_TRACE_COUNT] = count.to_s

              # Encode body & type
              env.headers[HEADER_CONTENT_TYPE] = encoder.content_type
              env.body = encoded_data

              # Query for response
              http_response = yield env

              # Process the response
              response_options = { trace_count: count }.tap do |options|
                # Parse service rates, if configured to do so.
                if service_rates? && !http_response.payload.to_s.empty?
                  body = JSON.parse(http_response.payload)
                  if body.is_a?(Hash) && body.key?(SERVICE_RATE_KEY)
                    options[:service_rates] = body[SERVICE_RATE_KEY]
                  end
                end
              end

              # Build and return a trace response
              Traces::Response.new(http_response, response_options)
            end
          end
        end

        # Add traces behavior to transport components
        HTTP::Client.send(:include, Traces::Client)
        HTTP::API::Spec.send(:include, Traces::API::Spec)
        HTTP::API::Instance.send(:include, Traces::API::Instance)
      end
    end
  end
end
