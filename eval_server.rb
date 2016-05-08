require 'socket'

def main(port)
  binding = TOPLEVEL_BINDING
  Socket.tcp_server_loop(port) do |sock|
    begin
      code = sock.read
      result = binding.eval(code)
      sock.write result.inspect
    rescue Exception => e
      sock.write e.message
    ensure
      sock.close
    end
  end
end

main(ARGV[0].to_i)

