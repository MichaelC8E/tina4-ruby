# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "json"

module Tina4
  module SessionHandlers
    # Shared RESP-protocol session storage. Redis and Valkey speak the same RESP
    # wire protocol, so reading, writing, destroying and cleaning up a session --
    # and building the optional `redis`-gem client -- are byte-identical between
    # them. Only the env-var namespace differs (TINA4_SESSION_REDIS_* vs
    # TINA4_SESSION_VALKEY_*), which each handler sets in its own initialize.
    #
    # A handler includes this and, in initialize, sets @prefix, @ttl, @host,
    # @port, @db, @password, @redis (the gem client or nil) and @resp (the raw
    # RespClient fallback, used when @redis is nil).
    module RespSessionHandler
      def read(session_id)
        key = "#{@prefix}#{session_id}"
        data = @redis ? @redis.get(key) : @resp.get(key)
        return nil unless data
        JSON.parse(data)
      rescue JSON::ParserError
        nil
      end

      # Write session data. A per-call +ttl+ WINS over the handler default, so
      # asking for a 60s session really gets 60s; 0 uses the default. Every
      # handler in every Tina4 framework takes this third argument -- Session#write
      # passes it, and a handler that did not accept it raised ArgumentError,
      # which safe_write swallowed into a silent STALE write.
      #
      # @param session_id [String] the session id
      # @param data [Hash] the payload to store
      # @param ttl [Integer] per-call lifetime in seconds; 0 uses the handler default
      def write(session_id, data, ttl = 0)
        key = "#{@prefix}#{session_id}"
        payload = JSON.generate(data)
        effective_ttl = ttl.to_i.positive? ? ttl.to_i : @ttl
        if @redis
          @redis.setex(key, effective_ttl, payload)
        else
          @resp.setex(key, effective_ttl, payload)
        end
      end

      def destroy(session_id)
        key = "#{@prefix}#{session_id}"
        @redis ? @redis.del(key) : @resp.del(key)
      end

      def cleanup
        # Redis/Valkey expire keys by TTL automatically -- nothing to sweep.
      end

      private

      # Use the official `redis` gem (RESP-compatible with both Redis and
      # Valkey) only when the REAL gem is loadable (guard against an in-test fake
      # `Redis` constant that has no VERSION). Returns nil when the gem is absent
      # so the caller falls back to the raw RESP client.
      def build_gem_client
        require "redis"
        return nil unless defined?(::Redis::VERSION)
        Redis.new(host: @host, port: @port, db: @db, password: @password)
      rescue LoadError
        nil
      end
    end
  end
end
