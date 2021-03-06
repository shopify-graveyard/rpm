# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'new_relic/agent/browser_token'
require 'new_relic/agent/traced_method_stack'

module NewRelic
  module Agent

    # This is THE location to store thread local information during a transaction
    # Need a new piece of data? Add a method here, NOT a new thread local variable.
    class TransactionState

      def self.get
        state_for(Thread.current)
      end

      # This method should only be used by TransactionState for access to the
      # current thread's state or to provide read-only accessors for other threads
      #
      # If ever exposed, this requires additional synchronization
      def self.state_for(thread)
        thread[:newrelic_transaction_state] ||= TransactionState.new
      end
      private_class_method :state_for

      def self.clear
        Thread.current[:newrelic_transaction_state] = nil
      end

      # This starts the timer for the transaction.
      def self.reset
        self.get.reset
      end

      def self.request=(request)
        self.get.request = request
      end

      def initialize
        @traced_method_stack = TracedMethodStack.new
        @current_transaction = nil
      end

      def request=(request)
        @request = request
        @request_token = BrowserToken.get_token(request)
      end

      def reset
        # We almost always want to use the transaction time, but in case it's
        # not available, we track the last reset. No accessor, as only the
        # TransactionState class should use it.
        @last_reset_time = Time.now
        @most_recent_transaction = nil
        @timings = nil
        @request = nil
        @request_token = nil
        @request_ignore_enduser = false
        @is_cross_app_caller = false
        @referring_transaction_info = nil
      end

      def timings
        @timings ||= TransactionTimings.new(transaction_queue_time, transaction_start_time, transaction_name)
      end

      # Cross app tracing
      # Because we need values from headers before the transaction actually starts
      attr_accessor :client_cross_app_id, :referring_transaction_info, :is_cross_app_caller

      def is_cross_app_caller?
        @is_cross_app_caller
      end

      def is_cross_app_callee?
        referring_transaction_info != nil
      end

      def request_guid_for_event
        return nil unless is_cross_app_callee? || is_cross_app_caller? || include_guid?
        request_guid
      end

      # Request data
      attr_reader :request
      attr_accessor :request_token, :request_ignore_enduser

      def request_guid
        return nil unless most_recent_transaction
        most_recent_transaction.guid
      end

      def request_guid_to_include
        return "" unless include_guid?
        request_guid
      end

      def include_guid?
        request_token && timings.app_time_in_seconds > most_recent_transaction.apdex_t
      end

      # Current transaction stack and sample building
      attr_accessor :most_recent_transaction, :transaction_sample_builder,
                    :current_transaction

      def transaction_start_time
        if most_recent_transaction.nil?
          @last_reset_time
        else
          most_recent_transaction.start_time
        end
      end

      def transaction_queue_time
        most_recent_transaction.nil? ? 0.0 : most_recent_transaction.queue_time
      end

      def transaction_name
        most_recent_transaction.nil? ? nil : most_recent_transaction.best_name
      end

      def transaction_noticed_error_ids
        most_recent_transaction.nil? ? [] : most_recent_transaction.noticed_error_ids
      end

      def self.in_background_transaction?(thread)
        state_for(thread).in_background_transaction?
      end

      def self.in_request_transaction?(thread)
        state_for(thread).in_request_transaction?
      end

      def in_background_transaction?
        !current_transaction.nil? && current_transaction.request.nil?
      end

      def in_request_transaction?
        !current_transaction.nil? && !current_transaction.request.nil?
      end

      # Execution tracing on current thread
      attr_accessor :untraced

      def push_traced(should_trace)
        @untraced ||= []
        @untraced << should_trace
      end

      def pop_traced
        @untraced.pop if @untraced
      end

      def is_traced?
        @untraced.nil? || @untraced.last != false
      end

      # TT's and SQL
      attr_accessor :record_tt, :record_sql

      def is_transaction_traced?
        @record_tt != false
      end

      def is_sql_recorded?
        @record_sql != false
      end

      # Busy calculator
      attr_accessor :busy_entries

      # Sql Sampler Transaction Data
      attr_accessor :sql_sampler_transaction_data

      # Scope stack tracking from NewRelic::StatsEngine::Transactions
      # Should not be nil--this class manages its initialization and resetting
      attr_reader :traced_method_stack
    end
  end
end
