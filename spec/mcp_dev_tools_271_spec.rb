# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"
require "securerandom"

# tina4-php#271 regression tests for the dev-MCP tools, at parity with Python.
# No mocks: a fresh subprocess (the dev-MCP server is a per-project singleton)
# boots a real temp SQLite DB, real routes, and is driven through the real
# JSON-RPC handler (McpServer#handle_message -> tools/call).
RSpec.describe "Dev-MCP tools (tina4-php#271)" do
  LIB_271 = File.expand_path("../lib", __dir__)

  DRIVER_271 = <<~'RUBY'
    require "json"
    Dir.chdir(ARGV[0])
    ENV["TINA4_DEBUG"] = "true"
    ENV["TINA4_LOG_LEVEL"] = "NONE"
    ENV["TINA4_SECRET"] = "test-secret-do-not-use-in-prod-0000000000000000"
    ENV.delete("TINA4_DATABASE_URL")
    require "tina4"
    begin; require "tina4/dev"; rescue LoadError; end

    db = Tina4::Database.new("sqlite://app.db")
    Tina4.bind_database(db)
    db.execute("CREATE TABLE empty_widget (id INTEGER PRIMARY KEY, label TEXT NOT NULL, qty INTEGER)")
    db.commit rescue nil

    class GuardMiddleware
      def self.before_auth(request, response)
        [request, response]
      end
    end

    Tina4::Router.clear! rescue nil
    Tina4::Router.get("/open") { |_req, res| res.call({ ok: true }, 200) }
    Tina4::Router.get("/guarded", middleware: [GuardMiddleware]) { |_req, res| res.call({ ok: true }, 200) }
    Tina4::Router.post("/hook", middleware: [GuardMiddleware, "RateLimiter"]) { |_req, res| res.call({ ok: true }, 200) }.no_auth

    FileUtils.mkdir_p("src/routes")
    Tina4::Router.load_routes(File.join(Dir.pwd, "src", "routes"))

    server = Tina4::McpServer.new("/__dev/mcp", name: "271")
    Tina4::McpDevTools.register(server)

    call = lambda do |tool, arguments|
      raw = server.handle_message(JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
                                                "params" => { "name" => tool, "arguments" => arguments }))
      parsed = JSON.parse(raw)
      return { "rpc_error" => parsed["error"] } if parsed.key?("error")
      text = parsed.dig("result", "content", 0, "text")
      (JSON.parse(text) rescue text)
    end

    out = {}
    out["columns_empty"]   = call.call("database_columns", { "table" => "empty_widget" })
    out["columns_missing"] = call.call("database_columns", { "table" => "no_such_table" })
    out["method_missing_name"]  = call.call("api_method", { "class" => "Database" })
    out["method_missing_class"] = call.call("api_method", { "name" => "fetch" })
    out["method_unknown_key"]   = call.call("api_method", { "class" => "Database", "name" => "fetch", "bogus" => 1 })
    out["method_misnamed"]      = call.call("api_method", { "class_name" => "Database", "name" => "fetch" })
    out["method_ok"]            = call.call("api_method", { "class" => "Database", "name" => "fetch" })
    out["no_args_required_tool"] = call.call("database_query", {})
    out["routes_before"] = call.call("route_list", {})
    File.write("src/routes/late_arrival.rb", "Tina4::Router.get('/late') { |_q, r| r.call({ ok: true }, 200) }\n")
    out["routes_without_rescan"] = call.call("route_list", {}).map { |r| r["path"] }
    Tina4::Router.rescan_routes!
    out["routes_after_rescan"] = call.call("route_list", {}).map { |r| r["path"] }

    puts "<<<271>>>"
    puts JSON.generate(out)
    puts "<<<END>>>"
  RUBY

  before(:all) do
    @report = nil
    Dir.mktmpdir("tina4-mcp-271") do |dir|
      script = File.join(dir, "boot_#{SecureRandom.hex(4)}.rb")
      File.write(script, DRIVER_271)
      output = IO.popen({ "TINA4_NO_BROWSER" => "true" }, [RbConfig.ruby, "-I", LIB_271, script, dir],
                        err: %i[child out], &:read).force_encoding("UTF-8")
      json = output[/<<<271>>>\n(.*)\n<<<END>>>/m, 1]
      raise "driver produced no report:\n#{output}" if json.nil?

      @report = JSON.parse(json)
    end
  end

  let(:report) { @report }

  describe "P1 database_columns reads schema metadata" do
    it "returns the columns of an EMPTY table with name, type and nullability" do
      columns = report["columns_empty"]
      expect(columns).to be_a(Array)
      expect(columns.map { |c| c["name"] }).to eq(%w[id label qty])
      label = columns.find { |c| c["name"] == "label" }
      expect(label["type"]).to eq("TEXT")
      expect(label["nullable"]).to eq(false)
    end

    it "reports a missing table with a clear error, not []" do
      expect(report["columns_missing"]).to eq("error" => "table not found: no_such_table")
    end
  end

  describe "P2 argument validation before dispatch" do
    it "names the missing argument and what the tool takes" do
      expect(report["method_missing_name"]).to eq(
        "error" => "missing required argument 'name' (api_method takes class, name)"
      )
      expect(report["method_missing_class"]).to eq(
        "error" => "missing required argument 'class' (api_method takes class, name)"
      )
    end

    it "rejects unknown keys with the same actionable shape" do
      expect(report["method_unknown_key"]).to eq(
        "error" => "unknown argument 'bogus' (api_method takes class, name)"
      )
      expect(report["method_misnamed"]["error"]).to start_with("missing required argument 'class'")
    end

    it "validates every tool, never leaking a raw ArgumentError" do
      expect(report["no_args_required_tool"]).to eq(
        "error" => "missing required argument 'sql' (database_query takes sql, params)"
      )
      expect(report.values.select { |v| v.is_a?(Hash) && v.key?("rpc_error") }).to be_empty
    end

    it "populates params and return on api_method" do
      spec = report["method_ok"]
      expect(spec["signature"]).to include("fetch")
      expect(spec["params"]).not_to be_empty
      expect(spec["params"].first.keys).to match_array(%w[name type required default])
      expect(spec["params"].map { |p| p["name"] }).to include("sql")
      expect(spec).to have_key("return")
    end
  end

  describe "P3 route_list middleware" do
    it "lists attached middleware so a guarded noAuth route differs from an open one" do
      routes = report["routes_before"].to_h { |r| [[r["method"], r["path"]], r] }
      expect(routes[["GET", "/open"]]["middleware"]).to eq([])
      expect(routes[["GET", "/guarded"]]["middleware"]).to eq(["GuardMiddleware"])
      hook = routes[["POST", "/hook"]]
      expect(hook["auth_required"]).to eq(false)
      expect(hook["middleware"]).to eq(%w[GuardMiddleware RateLimiter])
      expect(hook.keys).to include("method", "path", "auth_required", "middleware")
    end
  end

  describe "P4 a route file added while the server runs" do
    it "is absent until the dev reload rescan, then appears in route_list" do
      expect(report["routes_without_rescan"]).not_to include("/late")
      expect(report["routes_after_rescan"]).to include("/late")
    end
  end
end
