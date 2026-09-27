# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# SQLite path-resolution CONTRACT (ADR-0086), the five cases the four frameworks
# must agree on. Real resolver, real files, real mkdir - no mocks.
#
# Fixture: tina4-documentation/plan/v3/fixtures/sqlite_path_contract.json

require "spec_helper"
require "tmpdir"

RSpec.describe Tina4::SqlitePathResolver do
  # A bare object extended with the module runs the REAL shared resolver the two
  # SQLite adapters use (no double).
  let(:resolver) { Object.new.extend(described_class) }

  it "memory passthrough" do
    expect(resolver.resolve_path("sqlite::memory:")).to eq(":memory:")
    expect(resolver.resolve_path("sqlite:///:memory:")).to eq(":memory:")
  end

  it "unix absolute passthrough no mkdir" do
    Dir.mktmpdir do |dir|
      abs_db = File.join(dir, "missing", "app.db") # parent does NOT exist
      expect(resolver.resolve_path("sqlite:///#{abs_db}")).to eq(abs_db)
      expect(File.exist?(File.dirname(abs_db))).to be(false), "absolute path must NOT auto-mkdir"
    end
  end

  it "drive letter absolute passthrough no mkdir" do
    # A Windows drive-letter path is recognised as absolute on EVERY OS and
    # returned untouched - never re-rooted under cwd.
    expect(resolver.resolve_path("sqlite:///C:/Users/app.db")).to eq("C:/Users/app.db")
    expect(resolver.resolve_path("sqlite:///C:\\Users\\app.db")).to eq("C:\\Users\\app.db")
  end

  it "relative under cwd creates parent mode 0775" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        old = File.umask(0) # so the requested 0775 lands unmasked and can be asserted
        begin
          resolved = resolver.resolve_path("sqlite:///sub/dir/app.db")
        ensure
          File.umask(old)
        end
        parent = File.join(Dir.pwd, "sub", "dir")
        expect(resolved).to eq(File.join(parent, "app.db"))
        expect(File.directory?(parent)).to be(true), "parent dir auto-created under cwd"
        expect(File.stat(parent).mode & 0o777).to eq(0o775)
      end
    end
  end

  it "relative escaping cwd is refused no mkdir" do
    Dir.mktmpdir do |root|
      work = File.join(root, "work")
      FileUtils.mkdir_p(work)
      outside = File.join(root, "escaped")
      Dir.chdir(work) do
        expect { resolver.resolve_path("sqlite:///../escaped/app.db") }
          .to raise_error(ArgumentError, /outside the project/)
      end
      expect(File.exist?(outside)).to be(false), "an escaping relative path must NOT create any directory"
    end
  end
end
