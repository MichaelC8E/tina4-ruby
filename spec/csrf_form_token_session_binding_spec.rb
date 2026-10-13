# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "json"
require "stringio"
require "tmpdir"

# A form token rendered during a request is bound to that request's session.
#
# The CSRF check compares a token's session_id with the session of the write
# that carries it, but it can only do so when the token HAS a session_id. The
# rendered token never had one: form_token read a process-wide id that no
# dispatch path set, so a token rendered for one browser was accepted on a
# write carrying any other browser's session cookie. These examples render the
# token through the real Rack app, in one browser, and post it in another.
RSpec.describe "CSRF form token session binding" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_csrf_binding") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    @saved_env = %w[TINA4_CSRF TINA4_SECRET TINA4_SESSION_PATH].to_h { |k| [k, ENV[k]] }
    ENV["TINA4_CSRF"] = "true"
    ENV["TINA4_SECRET"] = "test-csrf-secret-0123456789abcdef"
    ENV["TINA4_SESSION_PATH"] = File.join(tmp_dir, "sessions")
    # The process-wide fallback id is set by other specs; none of these rely on it.
    @saved_fallback_id = Tina4::Frond.form_token_session_id
    Tina4::Frond.form_token_session_id = ""
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    Tina4::Middleware.use(Tina4::CsrfMiddleware)

    Tina4::Router.get("/login") do |request, response|
      request.session.set("token", Tina4::Auth.get_token({ "user" => "victim" }))
      response.json({ logged_in: true })
    end
    Tina4::Router.get("/form") do |request, response|
      request.session.set("seen", true)
      response.html(Tina4::Frond.new.render_string("{{ form_token_value() }}"))
    end
    Tina4::Router.get("/fresh") do |_request, response|
      response.html(Tina4::Frond.new.render_string("{{ form_token_value() }}"))
    end
    Tina4::Router.get("/cached", middleware: ["ResponseCache:60"]) do |_request, response|
      response.html(Tina4::Frond.new.render_string("{{ form_token_value() }}"))
    end
    Tina4::Router.post("/save") do |_request, response|
      response.json({ saved: true })
    end
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Tina4::Frond.form_token_session_id = @saved_fallback_id
    FileUtils.rm_rf(tmp_dir)
  end

  # One cookie jar, sent with every request through the real Rack app.
  class BindingBrowser
    attr_reader :cookies

    def initialize(app)
      @app = app
      @cookies = {}
    end

    def get(path)
      request("GET", path, "")
    end

    def post(path, token)
      request("POST", path, JSON.generate({ "formToken" => token }))
    end

    private

    def request(method, path, body)
      env = {
        "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => "",
        "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147",
        "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/json",
        "CONTENT_LENGTH" => body.bytesize.to_s,
        "rack.input" => StringIO.new(body), "rack.url_scheme" => "http"
      }
      env["HTTP_COOKIE"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ") unless @cookies.empty?
      status, headers, body_parts = @app.call(env)
      headers = headers.transform_keys { |k| k.to_s.downcase }
      Array(headers["set-cookie"]).flat_map { |v| v.to_s.split("\n") }.each do |cookie|
        name, rest = cookie.split("=", 2)
        @cookies[name] = rest.split(";", 2).first
      end
      text = body_parts.respond_to?(:each) ? body_parts.to_enum(:each).to_a.join : body_parts.to_s
      [status, text]
    end
  end

  def rendered_token(browser, path = "/form")
    token = browser.get(path)[1].strip
    expect(token).to match(/\A[\w-]+\.[\w-]+\.[\w-]+\z/)
    token
  end

  it "refuses a token rendered for one session on another" do
    attacker = BindingBrowser.new(app)
    victim = BindingBrowser.new(app)
    stolen = rendered_token(attacker)
    victim.get("/login")
    rendered_token(victim)

    expect(victim.post("/save", stolen)[0]).to eq(403)
  end

  it "passes a token on the session that rendered it" do
    victim = BindingBrowser.new(app)
    victim.get("/login")
    own = rendered_token(victim)

    expect(victim.post("/save", own)[0]).to eq(200)
  end

  it "binds on a page that writes no session, and keeps that session" do
    # Nothing else stores the session on /fresh, so without a marker it would
    # send no cookie, and the visitor's own POST would arrive under a new id.
    visitor = BindingBrowser.new(app)
    other = BindingBrowser.new(app)
    token = rendered_token(visitor, "/fresh")
    expect(visitor.cookies).not_to be_empty
    visitor.get("/login")
    other.get("/login")

    expect(visitor.post("/save", token)[0]).to eq(200)
    expect(other.post("/save", token)[0]).to eq(403)
  end

  it "does not let the response cache replay one visitor's token to the next" do
    # The session cookie is set after the response cache decides to store the
    # page, so a page whose token is bound to a NEW session must not be stored:
    # every later visitor would be served the first visitor's token.
    first = BindingBrowser.new(app)
    second = BindingBrowser.new(app)
    first_token = rendered_token(first, "/cached")
    second_token = rendered_token(second, "/cached")

    expect(first.post("/save", first_token)[0]).not_to eq(403)
    expect(second.post("/save", second_token)[0]).not_to eq(403)
  end

  it "leaves a render after the request unbound" do
    BindingBrowser.new(app).get("/form")
    token = Tina4::Frond.new.render_string("{{ form_token_value() }}").to_s.strip

    expect(Tina4::Auth.valid_token(token)).not_to have_key("session_id")
  end
end
