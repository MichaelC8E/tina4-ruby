# frozen_string_literal: true

# FRAGMENTED MESSAGES (RFC 6455 section 5.4) are delivered whole. A browser sends a large message - a pasted image in a
# chat, base64 inside JSON - as a TEXT frame with FIN clear, then CONTINUATION frames. The first piece was emitted as
# the whole message and the rest ignored (found through tina4-nodejs's twin bug, "invalid json", 2026-09-30). The
# Python master assembles fragments. Real sockets and hand-built masked frames - no doubles.
require "spec_helper"
require "socket"
require "json"
require "securerandom"

RSpec.describe Tina4::WebSocket, "fragmented messages" do
  def client_frame(fin, opcode, payload)
    payload = payload.b
    mask = SecureRandom.random_bytes(4).bytes
    len = payload.bytesize
    head = [(fin ? 0x80 : 0) | opcode].pack("C")
    head << if len < 126 then [0x80 | len].pack("C")
            elsif len < 65_536 then [0x80 | 126, len].pack("Cn")
            else [0x80 | 127, len].pack("CQ>")
            end
    body = payload.bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack("C*")
    head + mask.pack("C*") + body
  end

  # A real socket pair: the server end goes through handle_upgrade; the client end reads the 101 and writes frames.
  def connect(ws)
    server_end, client_end = UNIXSocket.pair
    env = { "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==" }
    ws.handle_upgrade(env, server_end)
    head = +""
    head << client_end.readpartial(1024) until head.include?("\r\n\r\n")
    client_end
  end

  def wait_for(messages, count)
    50.times { break if messages.size >= count; sleep 0.02 }
    sleep 0.1
  end

  let(:ws) { described_class.new }
  let(:messages) { [] }
  let(:image) { JSON.generate(type: "user", content: "see this", image: "data:image/png;base64," + [SecureRandom.random_bytes(90_000)].pack("m0")) }

  before { ws.on(:message) { |_conn, data| messages << data } }

  it "delivers a TEXT message sent in pieces, with a PING between them, once and whole" do
    client = connect(ws)
    data = image.b
    third = (data.bytesize / 3.0).ceil
    client.write(client_frame(false, 0x1, data.byteslice(0, third)))
    client.write(client_frame(true, 0x9, "ping"))
    client.write(client_frame(false, 0x0, data.byteslice(third, third)))
    client.write(client_frame(true, 0x0, data.byteslice(2 * third, data.bytesize)))
    wait_for(messages, 1)
    expect(messages.size).to eq(1)
    expect(messages.first.b).to eq(image.b)
    expect(JSON.parse(messages.first.force_encoding("UTF-8"))["type"]).to eq("user")
    client.close
  end

  it "still delivers an unfragmented message as before" do
    client = connect(ws)
    client.write(client_frame(true, 0x1, "small"))
    wait_for(messages, 1)
    expect(messages).to eq(["small"])
    client.close
  end

  it "drops a continuation with no message started, and the next message is unaffected (negative)" do
    client = connect(ws)
    client.write(client_frame(true, 0x0, "stray"))
    client.write(client_frame(true, 0x1, "after"))
    wait_for(messages, 1)
    expect(messages).to eq(["after"])
    client.close
  end

  it "never delivers a fragmented BINARY message's pieces as text (negative)" do
    client = connect(ws)
    client.write(client_frame(false, 0x2, "\x01\x02"))
    client.write(client_frame(true, 0x0, "\x03\x04"))
    client.write(client_frame(true, 0x1, "text"))
    wait_for(messages, 1)
    expect(messages).to eq(["text"])
    client.close
  end
end
