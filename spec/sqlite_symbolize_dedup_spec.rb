# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "tmpdir"
require "fileutils"

# Characterisation lock for row/key symbolisation across BOTH SQLite classes.
#
# `symbolize_rows`/`symbolize_keys` were byte-identical copy-paste in
# Tina4::Drivers::SqliteDriver and Tina4::Adapters::Sqlite3Adapter (the
# adapter's own comment said "See the matching helper in
# drivers/sqlite_driver.rb"). They are now one shared home
# (Tina4::RowSymbolizer, included by both). This spec pins the exact output
# shape for every input class the helper handles -- multi-row set, NULL cells,
# the positional-Integer-key drop older gems emit, the single-hash convenience,
# and empty passthrough -- and asserts BOTH classes produce IDENTICAL output,
# so the extraction is proven behaviour-preserving and the two can never drift
# again.
#
# No mocks: the end-to-end cases drive real temp-file SQLite databases, and the
# helper itself is a pure function over its input rows.
RSpec.describe "SQLite row/key symbolisation parity (adapter + driver)" do
  # One connected instance of each class, against its own real SQLite file.
  # The driver exposes #execute, the adapter exposes #exec -- seed each with its
  # own write primitive so both hold the same real rows.
  around do |example|
    @dir = Dir.mktmpdir("tina4_symbolize")
    @driver = Tina4::Drivers::SqliteDriver.new
    @driver.connect("sqlite://#{@dir}/driver.db")
    @adapter = Tina4::Adapters::Sqlite3Adapter.new("sqlite://#{@dir}/adapter.db")
    seed = lambda do |run|
      run.call("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
      run.call("INSERT INTO users VALUES (1, 'Alice', 'a@x')")
      run.call("INSERT INTO users VALUES (2, NULL, 'b@x')")
    end
    seed.call(->(sql) { @driver.execute(sql) })
    seed.call(->(sql) { @adapter.exec(sql) })
    example.run
  ensure
    @driver&.close
    @adapter&.close
    FileUtils.remove_entry(@dir, true) if @dir
  end

  # Both symbolisers, called via their private method (send) so visibility is
  # preserved and the SAME rule is asserted on both classes.
  def symbolize_rows_both(rows)
    [@driver.send(:symbolize_rows, rows), @adapter.send(:symbolize_rows, rows)]
  end

  def symbolize_keys_both(hash)
    [@driver.send(:symbolize_keys, hash), @adapter.send(:symbolize_keys, hash)]
  end

  describe "real end-to-end reads hydrate to symbol-keyed Hashes" do
    it "driver#execute_query returns multi-row symbol-keyed hashes" do
      rows = @driver.execute_query("SELECT * FROM users ORDER BY id")
      expect(rows).to eq([{ id: 1, name: "Alice", email: "a@x" },
                          { id: 2, name: nil, email: "b@x" }])
      expect(rows.flat_map(&:keys)).to all(be_a(Symbol))
    end

    it "adapter#query returns multi-row symbol-keyed hashes" do
      rows = @adapter.query("SELECT * FROM users ORDER BY id")
      expect(rows).to eq([{ id: 1, name: "Alice", email: "a@x" },
                          { id: 2, name: nil, email: "b@x" }])
      expect(rows.flat_map(&:keys)).to all(be_a(Symbol))
    end
  end

  describe "symbolize_rows contract (both classes agree)" do
    it "maps a multi-row string-keyed set to symbol keys, preserving NULL as nil" do
      input = [{ "id" => 1, "name" => "Alice" }, { "id" => 2, "name" => nil }]
      results = symbolize_rows_both(input)
      expect(results).to all(eq([{ id: 1, name: "Alice" }, { id: 2, name: nil }]))
    end

    it "drops positional Integer keys older sqlite3 gems emit, keeping named cols" do
      # Older gems put both the string name AND a positional Integer key in the
      # row hash; the is_a?(String|Symbol) guard must drop the Integer keys.
      input = [{ "id" => 1, 0 => 1, "name" => "Alice", 1 => "Alice" }]
      results = symbolize_rows_both(input)
      expect(results).to all(eq([{ id: 1, name: "Alice" }]))
      results.each { |r| expect(r.first.keys).to all(be_a(Symbol)) }
    end

    it "passes an already-symbol-keyed row through as symbols" do
      results = symbolize_rows_both([{ id: 1, name: "Bob" }])
      expect(results).to all(eq([{ id: 1, name: "Bob" }]))
    end

    it "returns an empty array unchanged" do
      results = symbolize_rows_both([])
      expect(results).to all(eq([]))
    end
  end

  describe "symbolize_keys contract (both classes agree)" do
    it "symbolises a single hash's string keys" do
      results = symbolize_keys_both({ "id" => 7, "name" => "Zoe" })
      expect(results).to all(eq({ id: 7, name: "Zoe" }))
    end

    it "drops positional Integer keys from a single hash" do
      results = symbolize_keys_both({ "id" => 7, 0 => 7, "name" => "Zoe" })
      expect(results).to all(eq({ id: 7, name: "Zoe" }))
    end
  end

  describe "the two classes are byte-for-byte equivalent on shared inputs" do
    [
      [{ "a" => 1, "b" => "x" }, { "a" => 2, "b" => nil }],
      [{ "only" => "one" }],
      [],
    ].each_with_index do |input, i|
      it "produces identical symbolize_rows output for input ##{i}" do
        driver_out, adapter_out = symbolize_rows_both(input)
        expect(driver_out).to eq(adapter_out)
      end
    end
  end
end
