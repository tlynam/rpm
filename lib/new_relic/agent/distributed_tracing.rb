# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.
# frozen_string_literal: true

require_relative 'distributed_tracing/cross_app_payload'
require_relative 'distributed_tracing/cross_app_tracing'

require_relative 'distributed_tracing/distributed_trace_transport_type'
require_relative 'distributed_tracing/distributed_trace_payload'

require_relative 'distributed_tracing/trace_context'

module NewRelic
  module Agent
    #
    # This module contains helper methods related to Distributed
    # Tracing, an APM feature that ties together traces from multiple
    # apps in one view.  Use it to add distributed tracing to protocols
    # not already supported by the agent.
    #
    # @api public
    module DistributedTracing
      extend NewRelic::SupportabilityHelper
      extend self
      
      EMPTY_ARRAY = [].freeze

      # Create a payload object containing the current transaction's
      # tracing properties (e.g., duration, priority).  You can use
      # this object to generate headers to inject into a network
      # request, so that the downstream service can participate in a
      # distributed trace.
      #
      # @return [DistributedTracePayload] Payload for the current
      #                                   transaction, or +nil+ if we
      #                                   could not create the payload
      #
      # @api public
      #
      # @deprecated See {#create_distributed_trace_headers} instead.
      #
      def create_distributed_trace_payload
        Deprecator.deprecate :create_distributed_trace_payload, :create_distributed_trace_headers

        unless Agent.config[:'distributed_tracing.enabled']
          NewRelic::Agent.logger.warn "Not configured to create New Relic distributed trace payload"
          return nil
        end

        transaction = Transaction.tl_current
        transaction.distributed_tracer.create_distributed_trace_payload if transaction
      rescue => e
        NewRelic::Agent.logger.error 'error during create_distributed_trace_payload', e
        nil
      end

      # Decode a JSON string containing distributed trace properties
      # (e.g., calling application, priority) and apply them to the
      # current transaction.  You can use it to receive distributed
      # tracing information protocols the agent does not already
      # support.
      #
      # This method will fail if you call it after calling
      # {#create_distributed_trace_payload}.
      #
      # @param payload [String] Incoming distributed trace payload,
      #                         either as a JSON string or as a
      #                         header-friendly string returned from
      #                         {DistributedTracePayload#http_safe}
      #
      # @return nil
      #
      # @api public
      #
      # @deprecated See {#accept_distributed_trace_headers} instead
      #
      def accept_distributed_trace_payload payload
        Deprecator.deprecate :accept_distributed_trace_payload, :accept_distributed_trace_headers

        unless Agent.config[:'distributed_tracing.enabled']
          NewRelic::Agent.logger.warn "Not configured to accept New Relic distributed trace payload"
          return nil
        end

        return unless transaction = Transaction.tl_current
        transaction.distributed_tracer.accept_distributed_trace_payload(payload)
        nil
      rescue => e
        NewRelic::Agent.logger.error 'error during accept_distributed_trace_payload', e
        nil
      end


      # Adds the Distributed Trace headers so that the downstream service can participate in a
      # distributed trace. This method should be called every time an outbound call is made
      # since the header payload contains a timestamp.
      #
      # Distributed Tracing must be enabled to use this method.
      #
      # +insert_distributed_trace_headers+ always inserts W3C trace context headers and inserts
      # New Relic distributed tracing header by default. New Relic headers may be suppressed by
      # setting +exclude_new_relic_header+ to +true+ in your configuration file.
      #
      # @param headers           [Hash]     Is a Hash containing the distributed trace headers and
      #                                     values.
      #
      # @return           {Transaction}     The transaction the headers were inserted from,
      #                                     or +nil+ if headers were not inserted.
      #
      # @api public
      #
      def insert_distributed_trace_headers headers={}
        record_api_supportability_metric(:insert_distributed_trace_headers)

        unless Agent.config[:'distributed_tracing.enabled']
          NewRelic::Agent.logger.warn "Not configured to insert distributed trace headers"
          return nil
        end

        return unless valid_api_argument_class? headers, "headers", Hash

        return unless transaction = Transaction.tl_current

        transaction.distributed_tracer.insert_headers headers
        transaction
      rescue => e
        NewRelic::Agent.logger.error 'error during insert_distributed_trace_headers', e
        nil
      end

      # Accepts distributed tracing information from protocols the agent does
      # not already support by accepting distributed trace headers from another transaction.
      #
      # Calling this method is not necessary in a typical HTTP trace as
      # distributed tracing is already handled by the agent.
      #
      # When used, invoke this method as early as possible as calling after
      # the headers are already created will have no effect.
      #
      # This method accepts both W3C trace context and New Relic distributed tracing headers.
      # When both are present, only the W3C headers are utilized.
      #
      # @param headers         [Hash]     Incoming distributed trace payload,
      #                                   either as a JSON string or as a
      #                                   header-friendly string returned from
      #                                   {DistributedTracePayload#http_safe}
      #
      # @param transport_Type  [String]   May be one of:  +HTTP+, +HTTPS+, +Kafka+, +JMS+,
      #                                   +IronMQ+, +AMQP+, +Queue+, +Other+.  Values are
      #                                   case sensitive.  All other values result in +Unknown+
      #
      # @return {Transaction} if successful, +nil+ otherwise
      #
      # @api public
      #
      def accept_distributed_trace_headers headers, transport_type="HTTP"
        record_api_supportability_metric(:accept_distributed_trace_headers)

        unless Agent.config[:'distributed_tracing.enabled']
          NewRelic::Agent.logger.warn "Not configured to accept distributed trace headers"
          return nil
        end

        return unless valid_api_argument_class? headers, "headers", Hash
        return unless valid_api_argument_class? transport_type, "transport_type", String

        return unless transaction = Transaction.tl_current

        hdr = if transport_type.start_with? 'HTTP' 
          headers
        else # find the headers and transform them to match the expected format
          # check the most common case first
          hdr = {"HTTP_TRACEPARENT" => headers['traceparent'] ,"HTTP_TRACESTATE" => headers['tracestate'], "HTTP_NEWRELIC" => headers['newrelic']} 
          # if nothing was found, search for any casing for trace context headers
          hdr['HTTP_TRACEPARENT'] ||= (headers.detect{|k, v| k.to_s.downcase.end_with? 'traceparent'} || EMPTY_ARRAY)[1]
          hdr['HTTP_TRACESTATE'] ||= (headers.detect{|k, v| k.to_s.downcase.end_with? 'tracestate'} || EMPTY_ARRAY)[1]
          # check for the known cases used for new relic headers
          hdr['HTTP_NEWRELIC'] ||= (headers.detect{|k, v| k.to_s.downcase.end_with? 'newrelic', 'NEWRELIC', 'NewRelic'} || EMPTY_ARRAY)[1]
          hdr
        end

        transaction.distributed_tracer.accept_incoming_request hdr, transport_type
        transaction
    rescue => e
        NewRelic::Agent.logger.error 'error during accept_distributed_trace_headers', e
        nil
      end
    end
  end
end
