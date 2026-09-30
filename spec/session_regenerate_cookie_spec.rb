# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Parity guard for tina4stack/tina4-php#253.
#
# The upstream bug was PHP-only: under `tina4 serve` (the raw-socket server),
# PHP's native $_SESSION bridge re-emitted the session cookie only when the
# session was NEW at the start of the request. A mid-request
# session_regenerate_id() -- the standard session-fixation defence on login --
# rotated the id AFTER that check, so no Set-Cookie went out and the session was
# lost on the very next request.
#
# Ruby was never affected: dispatch_pipeline.rb's session_save re-emits the
# cookie whenever `sid != cookie_val` (the id the client sent), which covers a
# brand-new session AND a mid-request regenerate. A bug reported against one
# framework almost always exists in the others, so it earns a permanent
# regression test here too -- if the serve path ever stopped propagating a
# rotated id, this spec goes red.
#
# Proven over a REAL spawned Tina4::WebServer (no mocks), the exact path
# `tina4ruby serve` takes, mirroring spec/session_builtin_server_cookie_spec.rb.

require "spec_helper"
require "json"
require "socket"
require "timeout"
require_relative "support/shutdown_probe"

module SessionRegenerateCookieProbe
  module_function

  # A REAL Tina4::WebServer child:
  #   GET /regen  -- writes the session, rotates its id via #regenerate, returns
  #                  the new id and the stored counter.
  #   GET /whoami -- reads the id and counter back.
  def write_app(dir)
    lib = ShutdownProbe.worktree_lib
    app_path = File.join(dir, "app.rb")
    File.write(app_path, <<~RUBY)
      #{ShutdownProbe.load_guard(lib)}

      Tina4::Router.get("/regen") do |request, response|
        request.session.set("hit", request.session.get("hit").to_i + 1)
        new_id = request.session.regenerate
        response.json({ id: new_id, hit: request.session.get("hit") })
      end.no_auth

      Tina4::Router.get("/whoami") do |request, response|
        response.json({ id: request.session.id, hit: request.session.get("hit") })
      end.no_auth

      Tina4.initialize!(#{dir.inspect})
      application = Tina4::RackApp.new(root_dir: #{dir.inspect})
      Tina4::WebServer.new(application, host: "127.0.0.1",
                                        port: Integer(ENV.fetch("PROBE_PORT"))).start
    RUBY
    app_path
  end

  def boot
    dir = SpecTmpdir.create("tina4-session-regenerate-cookie")
    port = ShutdownProbe.free_port
    app_path = write_app(dir)
    log_path = File.join(dir, "server.log")

    child_env = ShutdownProbe.base_env("TINA4_OVERRIDE_CLIENT" => "true", "PROBE_PORT" => port.to_s)
    pid = spawn(child_env, RbConfig.ruby, app_path,
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    ShutdownProbe::Server.new(pid, port, dir, log_path).wait_until_serving!("/whoami")
  end

  # Raw socket request so every Set-Cookie header is visible.
  def raw_request(port, method, path, headers: {}, body: nil, timeout: 5)
    socket = Socket.tcp("127.0.0.1", port, connect_timeout: timeout)
    lines = ["#{method} #{path} HTTP/1.1", "Host: 127.0.0.1:#{port}", "Connection: close"]
    headers.each { |k, v| lines << "#{k}: #{v}" }
    if body
      lines << "Content-Type: application/json"
      lines << "Content-Length: #{body.bytesize}"
    end
    request = lines.join("\r\n") + "\r\n\r\n" + (body || "")
    socket.write(request)

    raw = +""
    begin
      Timeout.timeout(timeout) { loop { raw << socket.readpartial(4096) } }
    rescue EOFError, Timeout::Error, Errno::ECONNRESET
      # whatever we got is the answer
    end
    socket.close

    head, _sep, response_body = raw.partition("\r\n\r\n")
    header_lines = head.split("\r\n")
    status = header_lines.first.to_s[/\A\S+\s+(\d+)/, 1].to_i
    set_cookies = header_lines.select { |l| l =~ /\Aset-cookie:/i }
                              .map { |l| l.split(":", 2)[1].to_s.strip }
    { status: status, body: response_body, set_cookies: set_cookies }
  end

  # The tina4_session name=value pair from a set of Set-Cookie lines, or nil.
  def session_cookie(set_cookies)
    pair = set_cookies.find { |c| c.start_with?("tina4_session=") }
    pair&.split(";", 2)&.first&.strip
  end
end

RSpec.describe "Session contract - regenerate mid-request re-emits the cookie (parity guard, tina4-php#253)" do
  after(:each) { @server&.destroy! }

  it "regenerate_mid_request_re_emits_the_new_cookie_and_survives" do
    @server = SessionRegenerateCookieProbe.boot

    # Request 1: write + rotate the id in one request.
    regen = SessionRegenerateCookieProbe.raw_request(@server.port, "GET", "/regen")
    expect(regen[:status]).to eq(200), "regen must succeed\n--- server log ---\n#{@server.log}"
    first = JSON.parse(regen[:body])
    expect(first["hit"]).to eq(1), regen[:body]
    rotated_id = first["id"]
    expect(rotated_id).to be_a(String).and(satisfy { |s| !s.empty? })

    emitted = SessionRegenerateCookieProbe.session_cookie(regen[:set_cookies])
    expect(emitted).not_to be_nil,
      "a request that rotated the session id must emit a Set-Cookie; got #{regen[:set_cookies].inspect}"
    expect(emitted.split("=", 2)[1]).to eq(rotated_id),
      "the emitted cookie must carry the rotated id #{rotated_id.inspect}; got #{emitted.inspect}"

    # Request 2: replay the rotated cookie -- the session must resume under the
    # new id (counter persisted), not come back empty.
    whoami = SessionRegenerateCookieProbe.raw_request(@server.port, "GET", "/whoami",
                                                      headers: { "Cookie" => emitted })
    second = JSON.parse(whoami[:body])
    expect(second["hit"]).to eq(1),
      "the rotated session must survive to the next request (hit=1); got #{whoami[:body]}"
    expect(second["id"]).to eq(rotated_id),
      "the next request must run under the rotated id #{rotated_id.inspect}; got #{whoami[:body]}"
  end
end
