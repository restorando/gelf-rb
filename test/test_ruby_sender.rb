require 'helper'

class TestRubyUdpSender < Test::Unit::TestCase
  context "with ruby sender" do
    setup do
      @addresses = [['localhost', 12201], ['localhost', 12202]]
      @sender = GELF::RubyUdpSender.new(@addresses, 2)
      @datagrams1 = %w(d1 d2 d3)
      @datagrams2 = %w(e1 e2 e3)
    end

    context "send_datagrams" do
      setup do
        @sender.send_data(@datagrams1.join(""))
        @sender.send_data(@datagrams2.join(""))
      end

      before_should "be called 3 times with 1st and 2nd address" do
        UDPSocket.any_instance.expects(:send).times(3).with do |datagram, _, host, port|
          datagram =~ /d\d$/ && host == 'localhost' && port == 12201
        end
        UDPSocket.any_instance.expects(:send).times(3).with do |datagram, _, host, port|
          datagram =~ /e\d$/ && host == 'localhost' && port == 12202
        end
      end
    end
  end
end
