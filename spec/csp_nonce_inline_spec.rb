# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# The framework's own inline content runs under the strict default CSP (ADR-0088).
#
# The framework serves `default-src 'self'` by default. A browser refuses every
# inline <style>/<script> under that policy unless the element carries a nonce
# the Content-Security-Policy header also names. So the framework mints one nonce
# per response, injects 'nonce-<X>' into style-src AND script-src, and stamps the
# SAME value on every inline <style>/<script> it emits. It also de-inlines every
# style="..." attribute and on*= handler, because a nonce covers a <style>/
# <script> ELEMENT but never a style/event-handler attribute.
#
# NO MOCKS: every request is driven through the REAL Tina4::RackApp pipeline
# (the same code path a real HTTP request takes). The welcome page at "/" is the
# page the reported bug rendered unstyled.

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe "CSP nonce for framework inline content (ADR-0088)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_csp_nonce") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    clear_csp_env
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "public"))
    # No "/" route, so GET / falls through to the framework's own welcome page.
    Tina4::SecurityHeadersMiddleware.attach
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    clear_csp_env
    FileUtils.rm_rf(tmp_dir)
  end

  def clear_csp_env
    %w[TINA4_CSP TINA4_DEBUG TINA4_OVERRIDE_CLIENT TINA4_NO_AI_PORT].each { |k| ENV.delete(k) }
  end

  # Drive a REAL request through the REAL Rack app; return [status, headers, body].
  def get(path, debug: false)
    ENV["TINA4_DEBUG"] = "true" if debug
    env = {
      "REQUEST_METHOD" => "GET", "PATH_INFO" => path, "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147",
      "REMOTE_ADDR" => "127.0.0.1", # loopback so the /__dev dev-admin gate admits us
      "rack.input" => StringIO.new(""), "rack.url_scheme" => "http"
    }
    status, headers, body = app.call(env)
    [status, headers.transform_keys { |k| k.to_s.downcase }, body.is_a?(Array) ? body.join : body.to_s]
  ensure
    ENV.delete("TINA4_DEBUG") if debug
  end

  def csp_nonce(csp)
    csp[/'nonce-([^']+)'/, 1]
  end

  # Every inline <style>/<script> WITHOUT a src attribute must carry `nonce`.
  def assert_inline_tags_carry_nonce(body, nonce)
    opens = body.scan(/<style\b([^>]*)>/i) + body.scan(/<script\b([^>]*)>/i)
    opens.flatten.each do |attrs|
      next if attrs.include?("src=") # external script/link needs no nonce
      expect(attrs).to include(%(nonce="#{nonce}")), "inline tag <...#{attrs}> missing the header nonce"
    end
    opens
  end

  def assert_no_inline_attrs(body, what)
    expect(body).not_to include('style="'), "#{what} still emits a style= attribute"
    expect(body).not_to include('onclick="'), "#{what} still emits an inline onclick handler"
  end

  # ---------------------------------------------------- welcome page ("/")

  it "the welcome page header names a nonce in style-src AND script-src" do
    _status, headers, _body = get("/", debug: true)
    csp = headers["content-security-policy"]
    expect(csp).to include("default-src 'self'")
    directives = csp.split(";").map(&:strip).reject(&:empty?)
                    .to_h { |d| [d.split(/\s+/, 2).first, d] }
    expect(directives["style-src"]).to include("'nonce-")
    expect(directives["script-src"]).to include("'nonce-")
    expect(csp).not_to include("'unsafe-inline'")
  end

  it "every inline <style>/<script> on the welcome page carries the header nonce" do
    _status, headers, body = get("/", debug: true)
    nonce = csp_nonce(headers["content-security-policy"])
    expect(nonce).not_to be_nil
    opens = assert_inline_tags_carry_nonce(body, nonce)
    expect(opens.length).to be >= 2, "welcome page emitted no inline <style>/<script>"
  end

  it "the welcome page emits no inline style= or onclick= attribute" do
    _status, _headers, body = get("/", debug: true)
    expect(body).to include("Tina4Ruby"), "sanity: this is the welcome page"
    assert_no_inline_attrs(body, "the framework welcome page")
  end

  it "each response gets a distinct nonce (per-response)" do
    _s1, h1, _b1 = get("/", debug: true)
    _s2, h2, _b2 = get("/", debug: true)
    n1 = csp_nonce(h1["content-security-policy"])
    n2 = csp_nonce(h2["content-security-policy"])
    expect(n1).not_to be_nil
    expect(n2).not_to be_nil
    expect(n1).not_to eq(n2), "nonce reused across responses: #{n1}"
  end

  # ---------------------------------------------------- an error page (404)

  it "a 404 error page carries the nonce and no inline attributes" do
    status, headers, body = get("/no-such-route-#{rand(100_000)}")
    expect(status).to eq(404)
    nonce = csp_nonce(headers["content-security-policy"])
    expect(nonce).not_to be_nil, "404 CSP carries no nonce"
    assert_inline_tags_carry_nonce(body, nonce)
    assert_no_inline_attrs(body, "the framework 404 page")
  end

  # ---------------------------------------------------- dev admin (/__dev)

  it "the dev admin page (/__dev) emits no inline style= or onclick= attribute" do
    status, headers, body = get("/__dev", debug: true)
    expect(status).to eq(200), "dev admin should be served over loopback in debug mode"
    # The dev-admin dashboard is a CSP-clean SPA: external /__dev/js + /__dev/css
    # only, no inline <style>/<script>, no style=/onclick=. It is security-exempt
    # (like /swagger) so it carries no CSP header; when one IS present it must
    # name a nonce. Either way it emits zero inline attributes.
    assert_no_inline_attrs(body, "the dev admin page")
    expect(body).not_to match(/<style\b[^>]*>/i), "dev admin must not emit an inline <style>"
    expect(body).not_to match(/<script\b(?![^>]*\bsrc=)[^>]*>/i), "dev admin must not emit an inline <script>"
    csp = headers["content-security-policy"]
    expect(csp_nonce(csp)).not_to be_nil, "when /__dev sends a CSP it must name a nonce" unless csp.nil? || csp.empty?
  end
end
