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
    # Valkey-backed session handler. Valkey speaks the RESP protocol, so it works
    # through the `redis` gem when installed (parity with Python/Node); otherwise
    # it speaks raw RESP over a TCP socket via RespClient — zero dependencies.
    # Same behaviour as RedisHandler (read/write/destroy/cleanup and the
    # gem-client build come from the shared RespSessionHandler) but reads
    # VALKEY-prefixed configuration variables.
    class ValkeyHandler
      include RespSessionHandler

      def initialize(options = {})
        @prefix = options[:prefix] || ENV["TINA4_SESSION_VALKEY_PREFIX"] || "tina4:session:"
        # TINA4_SESSION_VALKEY_TTL stays as the valkey-specific override, but it
        # now falls back to TINA4_SESSION_TTL - the ONE session-lifetime variable
        # every backend must honour (ADR-0024) - instead of a hard-coded 86400.
        # 3600 matches Python (the master), PHP and Node.
        @ttl = (options[:ttl] || ENV["TINA4_SESSION_VALKEY_TTL"] || ENV["TINA4_SESSION_TTL"] || 3600).to_i
        @host = options[:host] || ENV["TINA4_SESSION_VALKEY_HOST"] || "localhost"
        @port = options[:port] || (ENV["TINA4_SESSION_VALKEY_PORT"] ? ENV["TINA4_SESSION_VALKEY_PORT"].to_i : 6379)
        @db = options[:db] || (ENV["TINA4_SESSION_VALKEY_DB"] ? ENV["TINA4_SESSION_VALKEY_DB"].to_i : 0)
        @password = options[:password] || ENV["TINA4_SESSION_VALKEY_PASSWORD"]
        @redis = build_gem_client
        @resp = @redis ? nil : RespClient.new(host: @host, port: @port, password: @password, db: @db)
      end
    end
  end
end
