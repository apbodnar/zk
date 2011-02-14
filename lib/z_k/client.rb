module ZK
  # a more ruby-friendly wrapper around the low-level drivers
  #
  class Client
    extend Forwardable

    DEFAULT_TIMEOUT = 10

    attr_reader :event_handler

    # for backwards compatibility
    alias :watcher :event_handler #:nodoc:

    def initialize(host, opts={})
      @event_handler = EventHandler.new(self)
      @cnx = ::Zookeeper.new(host, DEFAULT_TIMEOUT, get_default_watcher_block)
      @state = nil
    end

    def closed?
      defined?(::JRUBY_VERSION) ? jruby_closed? : mri_closed?
    end

    def jruby_closed?
      @cnx.state == Java::OrgApacheZookeeper::ZooKeeper::States::CLOSED
    end

    def mri_closed?
      @cnx.state or false
    rescue RuntimeError => e
      # gah, lame error parsing here
      raise e if (e.message != 'zookeeper handle is closed') and not defined?(::JRUBY_VERSION)
      true
    end

    def connected?
      wrap_state_closed_error { @cnx.connected? }
    end

    def associating?
      wrap_state_closed_error { @cnx.associating? }
    end

    def connecting?
      wrap_state_closed_error { @cnx.connecting? }
    end

    def create(path, data='', opts={})
      # ephemeral is the default mode for us

      h = { :path => path, :data => data, :ephemeral => true, :sequence => false }.merge(opts)

      case mode = h.delete(:mode)
      when :ephemeral_sequential
        h[:ephemeral] = h[:sequence] = true
      when :persistent_sequential
        h[:ephemeral] = false
        h[:sequence] = true
      when :persistent
        h[:ephemeral] = false
      end

      rv = check_rc(@cnx.create(h))
      opts[:callback] ? rv : rv[:path]
    end

    # TODO: improve callback handling
    def get(path, opts={})
      h = { :path => path }.merge(opts)

      setup_watcher(h)

      rv = check_rc(@cnx.get(h))

      opts[:callback] ? rv : rv.values_at(:data, :stat)
    end

    def set(path, data, opts={})
      h = { :path => path, :data => data }.merge(opts)

      rv = check_rc(@cnx.set(h))

      opts[:callback] ? nil : rv[:stat]
    end

    def stat(path, opts={})
      h = { :path => path }.merge(opts)

      setup_watcher(h)

      rv = @cnx.stat(h)

      return rv if opts[:callback] 

      case rv[:rc] 
      when Zookeeper::ZOK, Zookeeper::ZNONODE
        rv[:stat]
      else
        check_rc(rv) # throws the appropriate error
      end
    end

    # exists? is just sugar around stat, instead of 
    #   
    #   zk.stat('/path').exists?
    #
    # you can do
    #
    #   zk.exists?('/path')
    #
    # this only works for the synchronous version of stat. for async version,
    # this method will act *exactly* like stat
    #
    def exists?(path, opts={})
      rv = stat(path, opts)
      opts[:callback] ? rv : rv.exists?
    end

    def close!
      @event_handler.clear!
      wrap_state_closed_error { @cnx.close }
    end

    # TODO: improve callback handling
    def delete(path, opts={})
      h = { :path => path, :version => -1 }.merge(opts)
      rv = check_rc(@cnx.delete(h))
      nil
    end

    def children(path, opts={})
      h = { :path => path }.merge(opts)

      setup_watcher(h)

      rv = check_rc(@cnx.get_children(h))
      opts[:callback] ? nil : rv[:children]
    end

    def get_acl(path, opts={})
      h = { :path => path }.merge(opts)
      rv = check_rc(@cnx.get_acl(h))
      opts[:callback] ? nil : rv.values_at(:children, :stat)
    end

    def set_acl(path, acls, opts={})
      h = { :path => path, :acl => acls }.merge(opts)
      rv = check_rc(@cnx.set_acl(h))
      opts[:callback] ? nil : rv[:stat]
    end

    #--
    #
    # EXTENSIONS
    #
    # convenience methods for dealing with zookeeper (rm -rf, mkdir -p, etc)
    #
    #++
    
    # creates all parent paths and 'path' in zookeeper as nodes with zero data
    # opts should be valid options to ZooKeeper#create
    #---
    # TODO: write a non-recursive version of this. ruby doesn't have TCO, so
    # this could get expensive w/ psychotically long paths
    #
    def mkdir_p(path)
      create(path, '', :mode => :persistent)
    rescue Exceptions::NodeExists
      return
    rescue Exceptions::NoNode
      if File.dirname(path) == '/'
        # ok, we're screwed, blow up
        raise KeeperException, "could not create '/', something is wrong", caller
      end

      mkdir_p(File.dirname(path))
      retry
    end

    # recursively remove all children of path then remove path itself
    def rm_rf(paths)
      Array(paths).flatten.each do |path|
        begin
          children(path).each do |child|
            rm_rf(File.join(path, child))
          end

          delete(path)
          nil
        rescue Exceptions::NoNode
        end
      end
    end

    # will block the caller until +abs_node_path+ has been removed
    def block_until_node_deleted(abs_node_path)
      queue = Queue.new
      ev_sub = nil

      node_deletion_cb = lambda do |event|
        if event.node_deleted?
          queue << :locked
        else
          queue << :locked unless exists?(abs_node_path, :watch => true)
        end
      end

      ev_sub = watcher.register(abs_node_path, &node_deletion_cb)

      # set up the callback, but bail if we don't need to wait
      return true unless exists?(abs_node_path, :watch => true)  

      queue.pop # block waiting for node deletion
      true
    ensure
      # be sure we clean up after ourselves
      ev_sub.unregister if ev_sub
    end

    # creates a new locker based on the name you send in
    # @param [String] name the name of the lock you wish to use
    # @see ZooKeeper::Locker#initialize
    # @return ZooKeeper::Locker the lock using this connection and name
    # @example
    #   zk.locker("blah").lock!
    def locker(name)
      Locker.new(self, name)
    end

    # convenience method for acquiring a lock then executing a code block
    def with_lock(path, &b)
      locker(path).with_lock(&b)
    end

    # creates a new message queue of name _name_
    # @param [String] name the name of the queue
    # @return [ZooKeeper::MessageQueue] the queue object
    # @see ZooKeeper::MessageQueue#initialize
    # @example
    #   zk.queue("blah").publish({:some_data => "that is yaml serializable"})
    def queue(name)
      MessageQueue.new(self, name)
    end

    def set_debug_level(level) #:nodoc:
      if defined?(::JRUBY_VERSION)
        warn "set_debug_level is not implemented for JRuby" 
        return
      else
        num =
          case level
          when String, Symbol
            ZookeeperBase.const_get(:"ZOO_LOG_LEVEL_#{level.to_s.upcase}") rescue NameError
          when Integer
            level
          end

        raise ArgumentError, "#{level.inspect} is not a valid argument to set_debug_level" unless num

        @cnx.set_debug_level(num)
      end
    end

    # the state of the underlying connection
    def state #:nodoc:
      @cnx.state
    end

    protected
      def wrap_state_closed_error
        yield
      rescue RuntimeError => e
        # gah, lame error parsing here
        raise e unless e.message == 'zookeeper handle is closed'
        false
      end

      def get_default_watcher_block
        lambda do |hash|
          watcher_callback.tap do |cb|
            cb.call(hash)
          end
        end
      end

      def setup_watcher(opts)
        opts[:watcher] = watcher_callback if opts.delete(:watch)
      end

      def watcher_callback
        ZookeeperCallbacks::WatcherCallback.create { |event| @event_handler.process(event) }
      end

      def check_rc(hash)
        hash.tap do |h|
          if code = h[:rc]
            raise Exceptions::KeeperException.by_code(code) unless code == Zookeeper::ZOK
          end
        end
      end
  end
end

