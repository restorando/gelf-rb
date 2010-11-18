require 'helper'

HASH = {'short_message' => 'message', 'host' => 'somehost', 'level' => GELF::WARN}

RANDOM_DATA = ('A'..'Z').to_a

class TestNotifier < Test::Unit::TestCase
  should "allow access to host, port, max_chunk_size and default_options" do
    Socket.expects(:gethostname).returns('default_hostname')
    n = GELF::Notifier.new
    assert_equal ['localhost', 12201, 1420], [n.host, n.port, n.max_chunk_size]
    assert_equal({'level' => 0, 'host' => 'default_hostname'}, n.default_options)
    n.host, n.port, n.max_chunk_size, n.default_options = 'graylog2.org', 7777, :lan, {'host' => 'grayhost'}
    assert_equal ['graylog2.org', 7777, 8154], [n.host, n.port, n.max_chunk_size]
    assert_equal({'host' => 'grayhost'}, n.default_options)

    n.max_chunk_size = 1337.1
    assert_equal 1337, n.max_chunk_size
  end

  context "with notifier with mocked sender" do
    setup do
      Socket.stubs(:gethostname).returns('stubbed_hostname')
      @notifier = GELF::Notifier.new('host', 12345)
      @sender = mock
      @notifier.instance_variable_set('@sender', @sender)
    end

    context "extract_hash" do
      should "check arguments" do
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash) }
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, 1, 2, 3) }
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, 1) { 'block' }         }
      end

      should "work with hash" do
        assert_equal HASH, @notifier.__send__(:extract_hash, HASH)
      end

      should "work with any object which responds to #to_hash" do
        o = Object.new
        o.expects(:to_hash).returns(HASH)
        assert_equal HASH, @notifier.__send__(:extract_hash, o)
      end

      should "work with exception with backtrace" do
        e = RuntimeError.new('message')
        e.set_backtrace(caller)
        hash = @notifier.__send__(:extract_hash, e)
        assert_equal 'RuntimeError: message', hash['short_message']
        assert_match /Backtrace/, hash['full_message']
        assert_equal GELF::ERROR, hash['level']
      end

      should "work with exception without backtrace" do
        e = RuntimeError.new('message')
        hash = @notifier.__send__(:extract_hash, e)
        assert_match /Backtrace is not available/, hash['full_message']
      end

      should "work with exception and hash" do
        e, h = RuntimeError.new('message'), {'param' => 1, 'level' => GELF::FATAL, 'short_message' => 'will be hidden by exception'}
        hash = @notifier.__send__(:extract_hash, e, h)
        assert_equal 'RuntimeError: message', hash['short_message']
        assert_equal GELF::FATAL, hash['level']
        assert_equal 1, hash['param']
      end

      should "work with plain text" do
        hash = @notifier.__send__(:extract_hash, 'message')
        assert_equal 'message', hash['short_message']
        assert_equal GELF::INFO, hash['level']
      end

      should "work with plain text and hash" do
        hash = @notifier.__send__(:extract_hash, 'message', 'level' => GELF::WARN)
        assert_equal 'message', hash['short_message']
        assert_equal GELF::WARN, hash['level']
      end

      should "work with block yielding plain text" do
        hash = @notifier.__send__(:extract_hash) { HASH['short_message'] }
        assert_equal HASH['short_message'], hash['short_message']
        assert_equal GELF::DEBUG, hash['level']
      end

      should "covert hash keys to strings" do
        hash = @notifier.__send__(:extract_hash, :short_message => :message)
        assert hash.has_key?('short_message')
        assert !hash.has_key?(:short_message)
      end

      should "not overwrite keys on convert" do
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, :short_message => :message1, 'short_message' => 'message2') }
      end

      should "use default_options" do
        @notifier.default_options = {:file => 'somefile.rb', 'short_message' => 'will be hidden by explicit argument'}
        hash = @notifier.__send__(:extract_hash, HASH)
        assert_equal 'somefile.rb', hash['file']
        assert_not_equal 'will be hidden by explicit argument', hash['short_message']
      end

      should "be compatible with HoptoadNotifier" do
        # https://github.com/thoughtbot/hoptoad_notifier/blob/master/README.rdoc, section Going beyond exceptions
        hash = @notifier.__send__(:extract_hash, :error_class => 'Class', :error_message => 'Message')
        assert_equal 'Class: Message', hash['short_message']
      end
    end

    context "datagrams_from_hash" do
      should "not split short data" do
        datagrams = @notifier.__send__(:datagrams_from_hash, HASH)
        assert_equal 1, datagrams.count
        assert_equal "\170\234", datagrams[0][0..1]
      end

      should "split long data" do
        srand(1) # for stable tests
        hash = HASH.merge('something' => (0..3000).map { RANDOM_DATA[rand(RANDOM_DATA.count)] }.join) # or it will be compressed too good
        datagrams = @notifier.__send__(:datagrams_from_hash, hash)
        assert_equal 2, datagrams.count
        assert_equal "\036\017", datagrams[0][0..1]
        assert_equal "\036\017", datagrams[1][0..1]
      end
    end

    context "local cache" do
      should "call send datagrams after each notify!" do
        @sender.expects(:send_datagrams).twice
        2.times { @notifier.notify!(HASH) }
      end

      context "with enabled caching" do
        setup do
          @notifier.cache_size = 3
        end

        should "not send datagram immediately after notify!" do
          @sender.expects(:send_datagrams).never
          2.times { @notifier.notify!(HASH) }
        end

        should "send datagrams when cache is full" do
          @sender.expects(:send_datagrams).once
          3.times { @notifier.notify!(HASH) }
        end

        should "send datagrams when cache size is reduced" do
          @sender.expects(:send_datagrams).once
          2.times { @notifier.notify!(HASH) }
          @notifier.cache_size = 1
        end

        context "and caching limit is disabled" do
          setup do
            @notifier.cache_size = 0
            5.times { @notifier.notify!(HASH) }
          end

          before_should "not send datagrams when caching limit is disabled" do
            @sender.expects(:send_datagrams).never
          end

          should "send datagrams on send_pending_notifications" do
            @sender.expects(:send_datagrams).once
            @notifier.send_pending_notifications
          end
        end
      end
    end

    context "level threshold" do
      setup do
        @notifier.level = GELF::WARN
      end

      should "not send notifications with level below threshold" do
        @sender.expects(:send_datagrams).never
        @notifier.notify!(HASH.merge('level' => GELF::DEBUG))
      end

      should "not notifications with level equal or above threshold" do
        @sender.expects(:send_datagrams).once
        @notifier.notify!(HASH.merge('level' => GELF::WARN))
      end
    end

    context "logger compatibility" do
      should "call notify with overwritten level" do
        GELF::Levels.constants.each do |const|
          hash = HASH.merge('level' => -1)
          @notifier.expects(:notify!).with { |hash| hash['level'] == GELF.const_get(const) }
          @notifier.__send__(const.downcase, hash)
        end
      end

      should "implement add method" do
        @notifier.expects(:notify!).with do |hash|
          hash['short_message'] == 'Message' &&
          hash['level'] == GELF::INFO
        end
        @notifier.add(GELF::INFO, 'Message')
      end

      should "send pending notifications on #close" do
        @notifier.expects(:send_pending_notifications)
        @notifier.close
      end

      should "respond to query methods" do
        @notifier.level = GELF::ERROR
        GELF::Levels.constants.each do |const|
          if GELF.const_get(const) >= GELF::ERROR
            assert @notifier.__send__(const.to_s.downcase + '?')
          else
            assert !@notifier.__send__(const.to_s.downcase + '?')
          end
        end
      end
    end

    should "pass valid data to sender" do
      @sender.expects(:send_datagrams).with do |datagrams|
        datagrams.is_a?(Array) && datagrams[0].is_a?(String)
      end
      @notifier.notify!(HASH)
    end

    should "not rescue from invalid invocation of #notify!" do
      assert_raise(ArgumentError) { @notifier.notify!(:no_short_message => 'too bad') }
    end

    should "rescue from invalid invocation of #notify" do
      @notifier.expects(:notify!).with(instance_of(Hash)).raises(ArgumentError)
      @notifier.expects(:notify!).with(instance_of(ArgumentError))
      assert_nothing_raised { @notifier.notify(:no_short_message => 'too bad') }
    end
  end
end
