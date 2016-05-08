require 'celluloid/current'
require 'docker-api'
require 'socket'
require 'timeout'
require 'andand'
require 'faye/websocket'
require 'eventmachine'
require 'json'

class Evaluator
  include Celluloid

  finalizer :stop_container

  def initialize(timeout=10, lifetime=3600)
    @container = Docker::Container.create(
      Image: 'ruby:eval_server',
      Cmd: %w{ruby /root/eval_server.rb 11109})
    @container.start
    @timeout = timeout
    @timer = after(lifetime) {terminate}
  end

  def evaluate(code)
    @timer.pause
    ip = @container.json['NetworkSettings']['IPAddress']
    Timeout.timeout @timeout do
      Socket.tcp(ip, 11109) do |sock|
        sock.write code
        sock.close_write
        sock.read
      end
    end.tap {@timer.reset}
  end

  def stop_container
    @container.andand.stop
    @timer.andand.cancel
  end
end

class Bot
  include Celluloid

  def initialize(authorization, rooms)
    @r = Random.new
    @authorization = authorization
    @rooms = rooms
  end

  def connected(ws)
    auth_msg = {
      id: gen_id,
      type: "auth",
      authorization: @authorization,
      agent: "eval_bot",
      resource: "Contatta-1462506174341"
    }
    ws.send JSON.dump(auth_msg)
    @rooms.each do |room|
      join_msg = {
        to: room,
        type: 'team_join'
      }
      ws.send JSON.dump(join_msg)
    end
  end

  def handle_msg(data, ws)
    msg = JSON.parse data
    if msg['type'] == 'chat'
      content = msg['text']
      if content.andand.start_with? '>>'
        code = content[2..-1].strip
        result = eval_for code, msg['from']
        result = "=> #{result}"
        ws.send JSON.dump({
          to: msg['to'],
          id: gen_id,
          type: 'chat',
          # "from":"celluloid+95b47271dd034f7194609d16f1706a2f@xmpp.ryver.com",
          # "key":"00204505654952460288",
          text: result,
        })
      end
    end
  end

  def eval_for(code, user)
    id = "session_#{user}"
    if !Actor[id]
      Evaluator.supervise(as: id)
      sleep 1
    end
    evaluator = Actor[id]
    evaluator.evaluate code
  end

  def gen_id
    @r.base64 5
  end
end

class Connection
  include Celluloid

  finalizer :close_ws

  RYVER_URI = "wss://xmpp.ryver.com/json-websocket"
  PROTOCOLS = %(ratatoskr)

  def initialize(hc, *args)
    @handler = hc.new_link *args
  end

  def connect
    EM.run do
      @ws = Faye::WebSocket::Client.new(RYVER_URI, PROTOCOLS)
      @ws.on :open do
        p "connected"
        @handler.connected @ws
      end

      @ws.on :message do |event|
        # p event.data
        @handler.async.handle_msg event.data, @ws
      end

      @ws.on :close do
        terminate
      end

      @ws.on :error do
        raise "websocket error!"
      end
    end
  end

  def close_ws
    #@ws.close if @ws.andand.open?
  end
end

