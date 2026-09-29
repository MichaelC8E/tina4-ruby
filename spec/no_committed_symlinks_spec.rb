# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Real-subprocess lock-in for scripts/check-no-symlinks.sh -- the CI guard that
# refuses a committed symlink (git mode 120000). A committed absolute symlink is
# what broke Windows/Composer extraction in the sibling php framework, so every
# framework now carries the same guard for parity even where the tree has none.
#
# No mocks, no doubles, no stubs. Every case runs the REAL script in a fresh
# child process via Open3.capture3 against a REAL throwaway git repository and
# asserts on its real exit status and real output:
#   * positive -- against this working tree at HEAD it PASSES (exit 0), so the
#     spec doubles as a guard that HEAD carries no committed symlink;
#   * mutation -- a fresh git repo with ONE symlink staged makes it FAIL
#     (non-zero) and NAME the offending path. Restoring the tree (no symlink)
#     makes the same script PASS, proving the guard is a real gate, not a
#     tautology that could never go red.

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe "scripts/check-no-symlinks.sh" do
  repo_root = File.expand_path("..", __dir__)
  script    = File.join(repo_root, "scripts", "check-no-symlinks.sh")

  it "the guard script is present and executable" do
    expect(File).to exist(script)
    expect(File.executable?(script)).to be(true)
  end

  it "PASSES (exit 0) against the real repo at HEAD -- no committed symlinks" do
    stdout, stderr, status = Open3.capture3("sh", script, chdir: repo_root)
    expect(status.exitstatus).to eq(0), "expected pass, got:\n#{stdout}\n#{stderr}"
    expect(stdout).to include("OK: no committed symlinks")
  end

  # Prove the guard is a GATE by mutation: build a real git repo, stage a real
  # symlink, and watch the script go red naming the path; then remove it and
  # watch the same script go green in the same repo.
  it "FAILS (non-zero) and NAMES a committed symlink when one is staged" do
    skip "git not available" if which("git").nil?

    Dir.mktmpdir do |dir|
      FileUtils.cp(script, File.join(dir, "check-no-symlinks.sh"))
      run_git(dir, "init", "-q")
      run_git(dir, "config", "user.email", "test@example.com")
      run_git(dir, "config", "user.name", "Test")

      File.write(File.join(dir, "real_target.txt"), "hello\n")
      File.symlink("real_target.txt", File.join(dir, "danger_link.txt"))
      run_git(dir, "add", "-A")

      stdout, stderr, status = Open3.capture3("sh", "check-no-symlinks.sh", chdir: dir)
      output = stdout + stderr

      expect(status.exitstatus).not_to eq(0), "expected non-zero, got 0:\n#{output}"
      expect(output).to include("ERROR: committed symlinks are not allowed")
      expect(output).to include("danger_link.txt") # names the offending path
    end
  end

  it "PASSES again once the symlink is removed from the same repo (gate, not tautology)" do
    skip "git not available" if which("git").nil?

    Dir.mktmpdir do |dir|
      FileUtils.cp(script, File.join(dir, "check-no-symlinks.sh"))
      run_git(dir, "init", "-q")
      run_git(dir, "config", "user.email", "test@example.com")
      run_git(dir, "config", "user.name", "Test")

      File.write(File.join(dir, "real_target.txt"), "hello\n")
      File.symlink("real_target.txt", File.join(dir, "danger_link.txt"))
      run_git(dir, "add", "-A")

      _o, _e, red = Open3.capture3("sh", "check-no-symlinks.sh", chdir: dir)
      expect(red.exitstatus).not_to eq(0), "mutation did not go red"

      run_git(dir, "rm", "-q", "--cached", "danger_link.txt")
      File.delete(File.join(dir, "danger_link.txt"))

      stdout, stderr, green = Open3.capture3("sh", "check-no-symlinks.sh", chdir: dir)
      expect(green.exitstatus).to eq(0), "expected pass after removal, got:\n#{stdout}\n#{stderr}"
      expect(stdout).to include("OK: no committed symlinks")
    end
  end

  def run_git(dir, *args)
    _stdout, stderr, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?
  end

  def which(cmd)
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |path|
      exe = File.join(path, cmd)
      return exe if File.executable?(exe) && !File.directory?(exe)
    end
    nil
  end
end
