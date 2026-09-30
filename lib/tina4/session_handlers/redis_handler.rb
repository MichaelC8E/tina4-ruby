# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "json"
require_relative "resp_client"
require_relative "resp_session_handler"

module Tina4
  module SessionHandlers
    # Redis-backed session handler. Prefers the `redis` gem when it is installed
    # (parity with Python, which prefers redis-py the same way, INSIDE this one
    # handler rather than as a separate backend name — Node's `redis-npm`
    # backend did the latter and was retired 2026-07-31 as drift); otherwise
    # speaks raw RESP over a TCP socket via RespClient — zero dependencies, so a
    # Tina4 app stores sessions in Redis with no extra gem.
    #
    # read/write/destroy/cleanup and the gem-client build come from
    # RespSessionHandler (shared byte-for-byte with ValkeyHandler); only the
    # env-var namespace below differs.
    class RedisHandler
      include RespSessionHandler

      # Connection is configured from TINA4_SESSION_REDIS_* env vars (parity with
      # Python's RedisSessionHandler and the Ruby ValkeyHandler shape) so
      # TINA4_SESSION_BACKEND=redis can actually be pointed at a server by env.
      # An explicit constructor option always wins over the environment.
      def initialize(options = {})
        @prefix = options[:prefix] || ENV["TINA4_SESSION_REDIS_PREFIX"] || "tina4:session:"
        # TINA4_SESSION_TTL reaches every backend (ADR-0024); was a hard-coded
        # 86400. 3600 matches Python (the master), PHP and Node.
        @ttl = (options[:ttl] || ENV["TINA4_SESSION_TTL"] || 3600).to_i
        @host = options[:host] || ENV["TINA4_SESSION_REDIS_HOST"] || "localhost"
        @port = options[:port] || (ENV["TINA4_SESSION_REDIS_PORT"] ? ENV["TINA4_SESSION_REDIS_PORT"].to_i : 6379)
        @db = options[:db] || (ENV["TINA4_SESSION_REDIS_DB"] ? ENV["TINA4_SESSION_REDIS_DB"].to_i : 0)
        @password = options[:password] || ENV["TINA4_SESSION_REDIS_PASSWORD"]
        @redis = build_gem_client
        @resp = @redis ? nil : RespClient.new(host: @host, port: @port, password: @password, db: @db)
      end
    end
  end
end
