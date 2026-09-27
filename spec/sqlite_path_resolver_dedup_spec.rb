# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "tmpdir"
require "fileutils"

# Characterisation lock for SQLite path resolution across BOTH resolvers.
#
# `resolve_path` used to be copy-pasted into Tina4::Drivers::SqliteDriver and
# Tina4::Adapters::Sqlite3Adapter, with DRIFTED scheme-stripping (the driver's
# own comment flags this as "how the two drifted"). They are now one shared
# home (Tina4::SqlitePathResolver, extended by both). This spec pins the exact
# resolution for all four input classes — plus the sqlite3: alias forms — and
# asserts BOTH resolvers agree, so the extraction is proven behaviour-preserving
# and the two can never drift again.
#
# No mocks — the resolvers are pure functions (bar the relative auto-mkdir,
# exercised for real under a temp cwd).
RSpec.describe "SQLite path resolution parity (both resolvers)" do
  # The two class methods under test.
  def resolvers
    [Tina4::Drivers::SqliteDriver, Tina4::Adapters::Sqlite3Adapter]
  end

  describe ":memory: passthrough" do
    ["sqlite::memory:", "sqlite:///:memory:", ":memory:"].each do |input|
      it "resolves #{input.inspect} to ':memory:' in both resolvers" do
        results = resolvers.map { |r| r.resolve_path(input) }
        expect(results).to all(eq(":memory:"))
      end
    end
  end

  describe "unix-absolute passthrough" do
    ["sqlite:////var/data/app.db", "sqlite:/var/data/app.db"].each do |input|
      it "passes #{input.inspect} through as /var/data/app.db in both resolvers" do
        results = resolvers.map { |r| r.resolve_path(input) }
        expect(results).to all(eq("/var/data/app.db"))
      end
    end
  end

  describe "windows-absolute passthrough" do
    it "passes a drive-letter path through untouched in both resolvers" do
      results = resolvers.map { |r| r.resolve_path("sqlite:///C:/Users/app.db") }
      expect(results).to all(eq("C:/Users/app.db"))
    end
  end

  describe "sqlite3: alias parity" do
    {
      "sqlite3::memory:"        => ":memory:",
      "sqlite3:///:memory:"     => ":memory:",
      "sqlite3:////var/x/a.db"  => "/var/x/a.db",
    }.each do |input, expected|
      it "resolves alias #{input.inspect} identically in both resolvers" do
        results = resolvers.map { |r| r.resolve_path(input) }
        expect(results).to all(eq(expected))
      end
    end
  end

  describe "relative → cwd + parent auto-created" do
    it "resolves under cwd and creates the parent dir in both resolvers" do
      resolvers.each do |resolver|
        Dir.mktmpdir("tina4_resolve") do |tmp|
          Dir.chdir(tmp) do
            result = resolver.resolve_path("sqlite:///sub/dir/app.db")
            expect(result).to eq(File.join(Dir.pwd, "sub/dir/app.db"))
            expect(File.directory?(File.join(Dir.pwd, "sub/dir"))).to be(true)
          end
        end
      end
    end
  end
end
