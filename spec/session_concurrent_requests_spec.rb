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
require "digest"
require "socket"

# A request's save must not undo what another request did to the same session.
#
# Every request loads its session when it starts and saves it when it ends
# (Request#session builds one Tina4::Session per request; DispatchPipeline
# #session_save saves it after the handler). The save used to write back the
# WHOLE snapshot loaded at the start, so a request that was in flight across a
# logout put the logged-out session back the moment it saved anything: #destroy,
# #clear and #regenerate were all undone, and so was a privilege change made
# with #set. A copied session cookie outlived the logout meant to kill it.
#
# The save now writes only this request's own changes onto the record as it is
# stored NOW, and never re-creates a record removed after this request loaded
# it.
#
# Two Tina4::Session objects over one directory stand in for two concurrent
# requests. NO MOCKS: the real FileHandler on a real tmp dir, and every outcome
# is read straight off disk, never through the session under test.
RSpec.describe "Tina4::Session saves from concurrent requests" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_sess_concurrent") }
  let(:options) { { handler: :file, handler_options: { dir: tmp_dir } } }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  # What the server does at the start of a request: a fresh Session, started
  # from the cookie.
  def request(session_id = nil)
    session = Tina4::Session.new({ "HTTP_COOKIE" => "" }, options)
    session.start(session_id)
    session
  end

  def logged_in(more = {})
    session = request
    session.set("user", "alice")
    more.each { |key, value| session.set(key, value) }
    expect(session.save).to be(true)
    session.get_session_id
  end

  # The record on disk for session_id, or nil when there is none. Read from the
  # file itself ("sess_<sha256>.json", {"_data" => ..., "_expires" => ...}).
  def stored(session_id)
    path = File.join(tmp_dir, "sess_#{Digest::SHA256.hexdigest(session_id)}.json")
    return nil unless File.exist?(path)

    JSON.parse(File.read(path))["_data"]
  end

  describe "a request in flight does not undo a logout" do
    it "keeps a destroyed session destroyed" do
      sid = logged_in
      slow = request(sid)
      request(sid).destroy

      slow.set("cart", "one item")
      expect(slow.save).to be(true)

      expect(stored(sid)).to be_nil
      # The session has ended for the slow request too: no id, so no cookie.
      expect(slow.get_session_id).to be_nil
    end

    it "keeps a cleared session cleared" do
      sid = logged_in
      slow = request(sid)
      logout = request(sid)
      logout.clear
      expect(logout.save).to be(true)

      slow.set("cart", "one item")
      slow.save

      expect(stored(sid).to_h).not_to have_key("user")
    end

    it "does not bring back the id regenerate retired" do
      sid = logged_in
      slow = request(sid)
      new_id = request(sid).regenerate

      slow.set("cart", "one item")
      slow.save

      expect(stored(sid)).to be_nil
      expect(stored(new_id)).to eq("user" => "alice")
    end

    it "keeps a downgrade made with set" do
      sid = logged_in
      slow = request(sid)
      demote = request(sid)
      demote.set("user", "nobody")
      expect(demote.save).to be(true)

      slow.set("cart", "one item")
      expect(slow.save).to be(true)

      expect(stored(sid)).to eq("user" => "nobody", "cart" => "one item")
    end

    it "keeps the session ended for the rest of the slow request" do
      sid = logged_in
      slow = request(sid)
      request(sid).destroy

      slow.set("cart", "one item")
      slow.save
      slow.set("more", "after")
      slow.save

      expect(stored(sid)).to be_nil
    end
  end

  # The slow request calls #regenerate at its end (a privilege change, an SSO
  # callback) after another request ended or changed the session. What it
  # loaded must not reach the new id.
  describe "a regenerate in flight does not carry an ended session" do
    # The user of every session record on disk, read from the files themselves.
    def users_stored
      Dir.glob(File.join(tmp_dir, "sess_*.json")).map { |path| JSON.parse(File.read(path))["_data"]["user"] }
    end

    it "keeps a destroyed session ended" do
      sid = logged_in
      slow = request(sid)
      request(sid).destroy

      expect(slow.regenerate).to be_nil
      expect(slow.get_session_id).to be_nil
      expect(users_stored).not_to include("alice")
    end

    it "keeps a cleared session cleared" do
      sid = logged_in
      slow = request(sid)
      logout = request(sid)
      logout.clear
      expect(logout.save).to be(true)

      slow.regenerate

      expect(users_stored).not_to include("alice")
    end

    it "carries a downgrade along with the slow request's own change" do
      sid = logged_in
      slow = request(sid)
      slow.set("cart", "one item")
      demote = request(sid)
      demote.set("user", "nobody")
      expect(demote.save).to be(true)

      new_id = slow.regenerate

      expect(stored(new_id)).to eq("user" => "nobody", "cart" => "one item")
      expect(stored(sid)).to be_nil
    end

    it "keeps the login that won when a login is submitted twice" do
      # Both requests carry the same pre-login cookie. The first to finish
      # rotates the id; the other must not mint a second, empty session whose
      # cookie would replace it.
      anon = request
      anon.set("pending", "state")
      expect(anon.save).to be(true)
      first = request(anon.get_session_id)
      second = request(anon.get_session_id)

      second.set("user", "alice")
      winner = second.regenerate
      first.set("user", "alice")
      first.save

      expect(first.regenerate).to be_nil
      expect(first.get_session_id).to be_nil
      expect(stored(winner)).to eq("pending" => "state", "user" => "alice")
      expect(users_stored).to eq(["alice"])
    end

    it "keeps the winner of a login submitted twice in the documented order" do
      # docs/ruby/09-sessions-cookies.md: regenerate, then set the user.
      anon = request
      anon.set("pending", "state")
      expect(anon.save).to be(true)
      first = request(anon.get_session_id)
      second = request(anon.get_session_id)

      winner = second.regenerate
      second.set("user", "alice")
      expect(second.save).to be(true)

      expect(first.regenerate).to be_nil
      first.set("user", "alice")
      first.save

      expect(first.get_session_id).to be_nil
      expect(stored(winner)).to eq("pending" => "state", "user" => "alice")
      expect(users_stored).to eq(["alice"])
    end

    it "stores the user under the new id in the documented login" do
      # docs/ruby/09-sessions-cookies.md: regenerate, then set the user.
      anon = request
      anon.set("csrf", "token")
      expect(anon.save).to be(true)
      session = request(anon.get_session_id)

      new_id = session.regenerate
      session.set("user_id", 42)
      expect(session.save).to be(true)

      expect(stored(new_id)).to eq("csrf" => "token", "user_id" => 42)
      expect(stored(anon.get_session_id)).to be_nil
    end

    it "still starts afresh on a regenerate after this request's own destroy" do
      sid = logged_in
      session = request(sid)
      session.destroy

      new_id = session.regenerate

      expect(new_id).to be_a(String)
      expect(new_id).not_to eq(sid)
      expect(stored(sid)).to be_nil
    end
  end

  describe "concurrent requests keep each other's changes" do
    it "persists two requests setting different keys" do
      sid = logged_in
      first = request(sid)
      second = request(sid)
      first.set("theme", "dark")
      second.set("cart", "one item")
      expect(first.save).to be(true)
      expect(second.save).to be(true)

      expect(stored(sid)).to eq("user" => "alice", "theme" => "dark", "cart" => "one item")
    end

    it "keeps a key another request deleted deleted" do
      sid = logged_in("mfa" => "verified")
      slow = request(sid)
      other = request(sid)
      other.delete("mfa")
      expect(other.save).to be(true)

      slow.set("cart", "one item")
      expect(slow.save).to be(true)

      expect(stored(sid)).to eq("user" => "alice", "cart" => "one item")
    end

    it "clears keys another request added when clear runs" do
      sid = logged_in
      logout = request(sid)
      other = request(sid)
      other.set("mfa", "verified")
      expect(other.save).to be(true)

      logout.clear
      expect(logout.save).to be(true)

      expect(stored(sid)).to eq({})
    end

    it "lets the last save win when both change one key" do
      sid = logged_in
      first = request(sid)
      second = request(sid)
      first.set("user", "bob")
      second.set("user", "carol")
      first.save
      second.save

      expect(stored(sid)["user"]).to eq("carol")
    end
  end

  describe "a save still writes what the request changed" do
    it "writes nothing for a read-only request" do
      sid = logged_in
      before = File.mtime(File.join(tmp_dir, "sess_#{Digest::SHA256.hexdigest(sid)}.json"))
      session = request(sid)
      session.get("user")
      expect(session.save).to be(true)

      expect(File.mtime(File.join(tmp_dir, "sess_#{Digest::SHA256.hexdigest(sid)}.json"))).to eq(before)
    end

    it "saves a value changed in place with the next set" do
      sid = logged_in("cart" => ["one item"])
      session = request(sid)
      session.get("cart") << "two items"
      session.set("seen", true)
      expect(session.save).to be(true)

      expect(stored(sid)["cart"]).to eq(["one item", "two items"])
    end

    it "writes a new session whole" do
      session = request
      session.set("user", "alice")
      session.set("theme", "dark")
      expect(session.save).to be(true)

      expect(stored(session.get_session_id)).to eq("user" => "alice", "theme" => "dark")
    end

    it "writes only what changed since the first save on a second save" do
      sid = logged_in
      session = request(sid)
      session.set("theme", "dark")
      expect(session.save).to be(true)
      other = request(sid)
      other.set("user", "nobody")
      other.set("theme", "light")
      expect(other.save).to be(true)

      session.set("cart", "one item")
      expect(session.save).to be(true)

      expect(stored(sid)).to eq("user" => "nobody", "theme" => "light", "cart" => "one item")
    end

    it "does not bring a new session back on a later save once it is destroyed" do
      session = request
      session.set("user", "alice")
      expect(session.save).to be(true)
      sid = session.get_session_id
      request(sid).destroy

      session.set("cart", "one item")
      session.save

      expect(stored(sid)).to be_nil
    end

    it "merges again on a save after clear and a save" do
      sid = logged_in
      session = request(sid)
      session.clear
      session.set("theme", "dark")
      expect(session.save).to be(true)
      other = request(sid)
      other.set("mfa", "verified")
      expect(other.save).to be(true)

      session.set("cart", "one item")
      expect(session.save).to be(true)

      expect(stored(sid)).to eq("theme" => "dark", "mfa" => "verified", "cart" => "one item")
    end

    it "still stores a set after clear and a save" do
      sid = logged_in
      session = request(sid)
      session.clear
      expect(session.save).to be(true)

      session.set("cart", "one item")
      expect(session.save).to be(true)

      expect(stored(sid)).to eq("cart" => "one item")
    end

    it "still stores a set after regenerating a session this request emptied" do
      # The SSO callback: consume the pending state, regenerate, store the identity.
      anon = request
      anon.set("pending", "state")
      expect(anon.save).to be(true)
      session = request(anon.get_session_id)
      session.delete("pending")
      new_id = session.regenerate

      session.set("user", "alice")
      expect(session.save).to be(true)

      expect(stored(new_id)).to eq("user" => "alice")
      expect(session.get_session_id).to eq(new_id)
    end

    it "writes only the new data after clear then set in one request" do
      sid = logged_in("theme" => "dark")
      session = request(sid)
      session.clear
      session.set("user", "bob")
      expect(session.save).to be(true)

      expect(stored(sid)).to eq("user" => "bob")
    end

    it "carries everything to the new id on regenerate" do
      sid = logged_in("theme" => "dark")
      new_id = request(sid).regenerate

      expect(stored(new_id)).to eq("user" => "alice", "theme" => "dark")
      expect(stored(sid)).to be_nil
    end
  end

  describe "a store that cannot be read at save time" do
    # Bind a port, learn its number, close it. Nothing is listening afterwards.
    def closed_port
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      port
    end

    it "writes nothing and keeps the change for a retry" do
      sid = logged_in
      session = request(sid)
      session.set("cart", "one item")

      # The store becomes unreachable between start and save: the REAL redis
      # handler, pointed at a port the kernel really refuses.
      file_handler = session.instance_variable_get(:@handler)
      session.instance_variable_set(:@handler,
                                    Tina4::SessionHandlers::RedisHandler.new(host: "127.0.0.1", port: closed_port))
      expect(session.save).to be(false)
      expect(stored(sid)).to eq("user" => "alice")

      session.instance_variable_set(:@handler, file_handler)
      expect(session.save).to be(true)
      expect(stored(sid)).to eq("user" => "alice", "cart" => "one item")
    end
  end
end
