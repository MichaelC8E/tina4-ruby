# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"

# parse_connection's URL regex used greedy quantifiers CodeQL flags as
# polynomial-redos. The fix makes each one possessive (\w++, [^@]++, [^:/]++,
# \d++). Possessive only changes what the engine tries on FAILURE, so every
# successful parse must be byte-identical -- that equivalence is what this spec
# pins. No mocks: the constructor opens no connection (connect is a separate,
# gem-lazy call) and parse_connection is a pure function over its argument.
# Mirrors the possessive hardening already shipped in template.rb / the other
# drivers (PR #120).
RSpec.describe "MssqlDriver#parse_connection ReDoS hardening" do
  let(:driver) { Tina4::Drivers::MssqlDriver.new }
  def parse(str) = driver.send(:parse_connection, str)

  it "parses a full user:pass@host:port/db URL" do
    expect(parse("mssql://sa:secret@localhost:1433/mydb")).to eq(
      username: "sa", password: "secret", host: "localhost", port: 1433, database: "mydb"
    )
  end

  it "parses the sqlserver:// scheme the same way" do
    expect(parse("sqlserver://sa:secret@db.example.com:1433/app")).to eq(
      username: "sa", password: "secret", host: "db.example.com", port: 1433, database: "app"
    )
  end

  it "parses a credential-less URL (optional group stays optional)" do
    expect(parse("mssql://localhost:1433/mydb")).to eq(
      username: nil, password: nil, host: "localhost", port: 1433, database: "mydb"
    )
  end

  it "parses a URL with no port" do
    expect(parse("mssql://localhost/mydb")).to eq(
      username: nil, password: nil, host: "localhost", port: nil, database: "mydb"
    )
  end

  it "keeps a colon inside the password ([^@]++ still spans it)" do
    # The possessive [^@]++ must still consume the ':' in the password exactly
    # as the greedy form did -- the '@' is the only thing that stops it.
    expect(parse("mssql://sa:p:a:ss@host/db")).to eq(
      username: "sa", password: "p:a:ss", host: "host", port: nil, database: "db"
    )
  end

  it "falls back to localhost for an unparseable string" do
    expect(parse("not a url")).to eq(host: "localhost", database: "not a url")
  end

  it "stays linear on a pathological no-slash input (no catastrophic backtracking)" do
    evil = "mssql://" + ("a" * 200_000)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    parse(evil)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    expect(elapsed).to be < 2.0
  end
end
