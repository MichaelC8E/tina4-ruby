# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# `tina4ruby migrate` gates deploys, so it MUST exit non-zero whenever it could
# not use the database. Tina4.initialize! logs a failed connection and leaves
# Tina4.database nil; the migrate commands used to print "No database
# configured" and exit 0 on that, so a deploy with a wrong or missing database
# URL carried on as though it had migrated.
#
# Spawns the REAL exe/tina4ruby in a temp project and asserts on the child's
# exit status. No mocks.

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"

RSpec.describe "tina4ruby migrate exit code" do
  EXE_PATH = File.expand_path("../exe/tina4ruby", __dir__)

  # clean: the refusal must be the CLI's own message, not a crash further
  # down that happens to be non-zero as well.
  def run_cli(args, url, clean: true)
    Dir.mktmpdir("tina4_cli_migrate_exit") do |dir|
      FileUtils.mkdir_p(File.join(dir, "migrations"))
      File.write(File.join(dir, "migrations", "000001_create_accounts.sql"),
                 "CREATE TABLE accounts (id INTEGER PRIMARY KEY)")
      env = {
        "TINA4_DATABASE_URL" => url,
        "TINA4_DATABASE_USERNAME" => nil,
        "TINA4_DATABASE_PASSWORD" => nil,
        "TINA4_AUTO_MIGRATE" => "false",
        "TINA4_DEBUG" => nil,
        "TINA4_SECRET" => "migrate-exit-spec-secret-0123456789"
      }
      output, status = Open3.capture2e(env, RbConfig.ruby, EXE_PATH, *args, chdir: dir)
      if clean && status.exitstatus != 0
        expect(output).not_to match(/^\s+from .*:\d+:in /), "migrate crashed instead of refusing; output:\n#{output}"
      end
      yield output, status.exitstatus, dir
    end
  end

  it "exits non-zero when the database URL names an unsupported engine" do
    run_cli(["migrate"], "nosuchengine://user:pass@127.0.0.1/app") do |output, exitstatus|
      expect(exitstatus).not_to eq(0), "migrate exited 0 without a database; output:\n#{output}"
      expect(output).to include("could not be opened")
    end
  end

  it "exits non-zero when no database is configured" do
    run_cli(["migrate"], nil) do |output, exitstatus|
      expect(exitstatus).not_to eq(0), "migrate exited 0 with no database; output:\n#{output}"
      expect(output).to include("No database configured")
    end
  end

  it "exits non-zero when the SQLite file cannot be opened" do
    # Connection is lazy here, so this one fails from inside the migration
    # runner with a backtrace -- non-zero, which is all a deploy needs.
    run_cli(["migrate"], "sqlite:////nonexistent-dir-for-tina4-spec/app.db", clean: false) do |output, exitstatus|
      expect(exitstatus).not_to eq(0), "migrate exited 0 on an unopenable database; output:\n#{output}"
    end
  end

  %w[migrate:status migrate:rollback].each do |command|
    it "#{command} exits non-zero when the database is unusable" do
      run_cli([command], "nosuchengine://user:pass@127.0.0.1/app") do |output, exitstatus|
        expect(exitstatus).not_to eq(0), "#{command} exited 0 without a database; output:\n#{output}"
      end
    end
  end

  it "exits zero when the database works" do
    Dir.mktmpdir("tina4_cli_migrate_exit_db") do |db_dir|
      db_path = File.join(db_dir, "app.db")
      run_cli(["migrate"], "sqlite:///#{db_path}") do |output, exitstatus|
        expect(exitstatus).to eq(0), "migrate failed against a working database; output:\n#{output}"
        expect(output).to include("000001_create_accounts")
      end
    end
  end
end
