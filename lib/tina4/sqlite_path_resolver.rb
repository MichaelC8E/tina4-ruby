# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "fileutils"

module Tina4
  # Shared SQLite database-path resolution for the two SQLite resolvers.
  #
  # `resolve_path` used to be copy-pasted into Tina4::Drivers::SqliteDriver and
  # Tina4::Adapters::Sqlite3Adapter with drifted scheme-stripping. This module is
  # the single home for the logic; both classes `extend` it, so both keep a
  # `.resolve_path` class method backed by ONE implementation and can never
  # drift again.
  #
  # Convention (matches tina4-python, tina4-php, tina4-nodejs):
  #   sqlite::memory:              → :memory:
  #   sqlite:///:memory:           → :memory:
  #   sqlite:///app.db             → {cwd}/app.db          (relative)
  #   sqlite:///data/app.db        → {cwd}/data/app.db     (relative; auto-mkdir under cwd)
  #   sqlite:////var/data/app.db   → /var/data/app.db      (absolute; no auto-mkdir)
  #   sqlite:///C:/Users/app.db    → C:/Users/app.db       (Windows absolute)
  #
  # `sqlite3:` is a documented alias for `sqlite:` and is normalised first.
  # Never mkdir outside cwd — that was the root cause of the
  # "Read-only file system: '/data'" crash on macOS.
  module SqlitePathResolver
    # Resolve a SQLite URL / path against the project root (cwd).
    #
    # @param connection_string [String] a sqlite: / sqlite3: URL or bare path
    # @return [String] the resolved path to hand to the driver, or ":memory:"
    def resolve_path(connection_string)
      return ":memory:" if connection_string == "sqlite::memory:" || connection_string == "sqlite:///:memory:"

      # `sqlite3:` is a documented alias for `sqlite:`; normalise it FIRST or the
      # strips below miss and the file ends up literally named "sqlite3:app.db"
      # (and a colon is an illegal filename character on Windows).
      normalised = connection_string.to_s.sub(/^sqlite3:/, "sqlite:")
      raw = normalised.sub(%r{^sqlite:///}, "").sub(%r{^sqlite://}, "").sub(/^sqlite:/, "")
      return ":memory:" if raw == ":memory:"

      is_windows_abs = raw.match?(%r{^[A-Za-z]:[/\\]})
      is_unix_abs    = raw.start_with?("/")

      if is_windows_abs || is_unix_abs
        # Absolute — trust the user; don't auto-mkdir outside cwd.
        raw
      else
        # Relative — resolve under cwd; create the parent (mode 0775) ONLY when
        # it stays inside cwd (ADR-0086). A relative path whose parent escapes
        # the project (e.g. "../../etc/foo.db") is REFUSED loudly here — never
        # the silent mkdir outside the project that used to happen.
        resolved = File.join(Dir.pwd, raw)
        parent = File.dirname(resolved)
        expanded_parent = File.expand_path(parent)
        cwd = File.expand_path(Dir.pwd)
        unless expanded_parent == cwd || expanded_parent.start_with?(cwd + File::SEPARATOR)
          raise ArgumentError,
                "SQLite path #{connection_string.inspect} resolves outside the project " \
                "directory: #{expanded_parent.inspect} is not within #{cwd.inspect}. " \
                "Tina4 refuses to create directories outside the project (ADR-0086). " \
                "Use an absolute path for a database that lives outside the project."
        end
        FileUtils.mkdir_p(parent, mode: 0o775) unless File.directory?(parent)
        resolved
      end
    end
  end
end
