module GELF
  # Plain Ruby UDP sender.
  class RubyUdpSender
    attr_accessor :addresses

    def initialize(addresses, max_chunk_size)
      @addresses = addresses
      @i = 0
      @socket = UDPSocket.open
      @max_chunk_size = max_chunk_size
    end

    def send_data(data)
      send_datagrams split_into_datagrams(data.bytes)
    end

    def close
      @socket.close
    end

    private

    def split_into_datagrams(data)
      datagrams = []

      # Maximum total size is 8192 byte for UDP datagram. Split to chunks if bigger. (GELF v1.0 supports chunking)
      if data.count > @max_chunk_size
        id = GELF::Notifier.last_chunk_id += 1
        msg_id = Digest::MD5.digest("#{Time.now.to_f}-#{id}")[0, 8]
        num, count = 0, (data.count.to_f / @max_chunk_size).ceil
        data.each_slice(@max_chunk_size) do |slice|
          datagrams << "\x1e\x0f" + msg_id + [num, count, *slice].pack('C*')
          num += 1
        end
      else
        datagrams << data.to_a.pack('C*')
      end

      datagrams
    end

    def send_datagrams(datagrams)
      host, port = @addresses[@i]
      @i = (@i + 1) % @addresses.length
      datagrams.each do |datagram|
        @socket.send(datagram, 0, host, port)
      end
    end

  end

  # Plain Ruby UDP sender.
  class RubyTcpSender
    attr_accessor :addresses

    def initialize(addresses, data_delimiter = "\0", timeout = 0.1)
      @addresses = addresses
      @i = 0
      @data_delimiter = data_delimiter
      @sockets = Hash.new do |sockets, index|
        sockets[index] = open_tcp_socket(*@addresses[index], timeout)
      end
    end

    def send_data(data)
      find_open_socket do |socket|
        socket.send data + @data_delimiter, 0
      end or $stderr.puts("Couldnt use any socket successfully, data was descarded")
    end

    def close
      @sockets.values.each(&:close)
      @sockets.clear
    end

    private

    def open_tcp_socket(host, port, timeout)
      addr = Socket.getaddrinfo(host, nil)
      sock = Socket.new(Socket.const_get(addr[0][0]), Socket::SOCK_STREAM, 0)

      if timeout
        secs = Integer(timeout)
        usecs = Integer((timeout - secs) * 1_000_000)
        optval = [secs, usecs].pack("l_2")
        sock.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, optval
        sock.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, optval
      end
      sock.connect(Socket.pack_sockaddr_in(port, addr[0][3]))
      sock
    end

    def find_open_socket(&block)
      (1..@addresses.size).find do
        @i = (@i + 1) % @addresses.length
        safe_socket_use(@i, &block)
      end
    end

    def safe_socket_use(index)
      yield @sockets[index]
      true

    rescue Errno::ECONNREFUSED, Errno::EPIPE
      @sockets.delete(index)
      false
    end
  end
end
