# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "tina4/migration"

# Characterization spec: pins the EXACT current behaviour of the migration
# split-SQL scanner before it is decomposed into helper methods. Every case
# asserts a full array so a refactor that changes what the scanner emits goes
# red. This is the safety net the CC-reduction refactor leans on; it mirrors
# the tina4-python _split_statements / tina4-php scanner contract (parity).
RSpec.describe "Tina4::Migration#split_sql_statements characterization" do
  # Pure string function — no @db is ever touched.
  let(:migration) { Tina4::Migration.allocate }

  def split(sql, delimiter = ";")
    migration.send(:split_sql_statements, sql, delimiter)
  end

  describe "plain statement splitting" do
    it "splits on ';' and strips each statement" do
      expect(split("SELECT 1; SELECT 2")).to eq(["SELECT 1", "SELECT 2"])
    end

    it "does not emit a trailing empty statement after a final ';'" do
      expect(split("SELECT 1; SELECT 2;")).to eq(["SELECT 1", "SELECT 2"])
    end

    it "drops empty statements between adjacent delimiters" do
      expect(split("SELECT 1;; SELECT 2;")).to eq(["SELECT 1", "SELECT 2"])
    end

    it "returns an empty array for blank input" do
      expect(split("   \n  ")).to eq([])
    end

    it "keeps the trailing statement when it has no delimiter" do
      expect(split("SELECT 1; SELECT 2")).to eq(["SELECT 1", "SELECT 2"])
    end
  end

  describe "comments" do
    it "strips a -- line comment but keeps the statement whole" do
      sql = "CREATE TABLE t (\n  id INT,  -- a; b; c\n  name TEXT\n);"
      stmts = split(sql)
      expect(stmts.length).to eq(1)
      expect(stmts[0]).not_to include("a; b; c")
      expect(stmts[0]).to include("id INT")
      expect(stmts[0]).to include("name TEXT")
    end

    it "strips a /* */ block comment and does not split on its inner ';'" do
      stmts = split("CREATE TABLE t (id INT /* a; b */, name TEXT);")
      expect(stmts.length).to eq(1)
      expect(stmts[0]).not_to include("a; b")
    end

    it "returns nothing for a script that is only a comment" do
      expect(split("-- just a comment\n")).to eq([])
    end
  end

  describe "string literals and quoted identifiers" do
    it "keeps a ';' inside a single-quoted string" do
      stmts = split("INSERT INTO t (v) VALUES ('a;b;c'); INSERT INTO t (v) VALUES ('d');")
      expect(stmts).to eq(["INSERT INTO t (v) VALUES ('a;b;c')", "INSERT INTO t (v) VALUES ('d')"])
    end

    it "does not treat '--' inside a single-quoted string as a comment" do
      stmts = split("INSERT INTO t (v) VALUES ('a--b'); INSERT INTO t (v) VALUES ('c');")
      expect(stmts).to eq(["INSERT INTO t (v) VALUES ('a--b')", "INSERT INTO t (v) VALUES ('c')"])
    end

    it "honours the '' doubled-quote escape inside a single-quoted string" do
      stmts = split("INSERT INTO t (v) VALUES ('O''Brien; Jr'); SELECT 1;")
      expect(stmts).to eq(["INSERT INTO t (v) VALUES ('O''Brien; Jr')", "SELECT 1"])
    end

    it "keeps a ';' inside a double-quoted identifier" do
      stmts = split('CREATE TABLE "a;b" (x INT); SELECT 1;')
      expect(stmts).to eq(['CREATE TABLE "a;b" (x INT)', "SELECT 1"])
    end

    it "honours the double doubled-quote escape inside an identifier" do
      stmts = split('SELECT "a""b;c"; SELECT 2;')
      expect(stmts).to eq(['SELECT "a""b;c"', "SELECT 2"])
    end
  end

  describe "stored-proc blocks" do
    it "keeps a $$ ... $$ block intact (inner ';' never splits)" do
      stmts = split("CREATE FUNCTION f() AS $$ BEGIN a; b; END $$; SELECT 3;")
      expect(stmts).to eq(["CREATE FUNCTION f() AS $$ BEGIN a; b; END $$", "SELECT 3"])
    end

    it "keeps a // ... // block intact" do
      stmts = split("CREATE PROCEDURE foo() // BEGIN SELECT 1; SELECT 2; END //;")
      expect(stmts.any? { |s| s.include?("BEGIN SELECT 1; SELECT 2; END") }).to be(true)
    end

    it "does not treat a :// URL scheme as a // block delimiter" do
      sql = "INSERT INTO cfg (k, v) VALUES ('a', 'https://a.example.com');\n" \
            "INSERT INTO cfg (k, v) VALUES ('b', 'https://b.example.com');"
      stmts = split(sql)
      expect(stmts.length).to eq(2)
      expect(stmts[0]).to include("https://a.example.com")
      expect(stmts[1]).to include("https://b.example.com")
    end
  end

  describe "SET TERM directive" do
    it "keeps a trigger body intact and consumes the directives" do
      sql = "SET TERM ^ ;\n" \
            "CREATE TRIGGER t_bi FOR t AS BEGIN NEW.id = 1; END^\n" \
            "SET TERM ; ^"
      stmts = split(sql)
      expect(stmts.length).to eq(1)
      expect(stmts[0]).to start_with("CREATE TRIGGER")
      expect(stmts[0]).to include("NEW.id = 1;")
      expect(stmts.none? { |s| s.include?("SET TERM") }).to be(true)
    end

    it "restores the previous delimiter after the block" do
      sql = "CREATE TABLE a (id INT);\n" \
            "SET TERM ^ ;\n" \
            "CREATE TRIGGER a_bi FOR a AS BEGIN NEW.id = 1; END^\n" \
            "SET TERM ; ^\n" \
            "INSERT INTO a VALUES (1);\nUPDATE a SET id = 2;"
      stmts = split(sql)
      expect(stmts.length).to eq(4)
      expect(stmts.map { |s| s[/\A\w+ \w+/] }).to eq(["CREATE TABLE", "CREATE TRIGGER", "INSERT INTO", "UPDATE a"])
    end

    it "supports a multi-character terminator" do
      stmts = split("SET TERM !! ;\nCREATE TRIGGER t FOR x AS BEGIN NEW.a = 1; END!!\nSET TERM ; !!")
      expect(stmts.length).to eq(1)
      expect(stmts[0]).not_to include("!!")
      expect(stmts[0]).not_to include("SET TERM")
    end

    it "treats a trailing SET TERM as a no-op (never emitted)" do
      expect(split("SELECT 1;\nSET TERM ^ ;")).to eq(["SELECT 1"])
    end
  end

  describe "delimiter and normalization edges" do
    it "splits on a custom single-character delimiter" do
      expect(split("SELECT 1! SELECT 2!", "!")).to eq(["SELECT 1", "SELECT 2"])
    end

    it "returns the whole script as one statement when the delimiter is empty" do
      expect(split("SELECT 1; SELECT 2", "")).to eq(["SELECT 1; SELECT 2"])
    end

    it "normalizes smart quotes to straight ASCII before splitting" do
      joined = split("CREATE TABLE “users” (name TEXT DEFAULT ‘guest’);").join(" ")
      ["“", "”", "‘", "’"].each { |smart| expect(joined).not_to include(smart) }
      expect(joined).to include('"users"')
      expect(joined).to include("'guest'")
    end
  end
end
