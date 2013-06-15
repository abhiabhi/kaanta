module Kaanta

  class Master
    SIGNALS = %w(QUIT INT TERM).map { |x| x.freeze }.freeze

    def initialize
      @rpipe, @wpipe  = IO.pipe
      @workers        = {}
      @sig_queue      = []
    end

    def start
      $PROGRAM_NAME = "kaanta master"
      @master_pid = Process.pid
      $stderr.sync = $stdout.sync = true
      setup_logging
      @socket = TCPServer.open(Config.host, Config.port)
      logger.info("Listening on #{Config.host}: #{Config.port}")
      logger.info("Spawning #{Config.workers} workers")
      spawn_workers
      SIGNALS.each { |sig| trap_deferred(sig) }
      trap('CHLD') { @wpipe.write_nonblock(".") }

      loop do
        reap_workers
        case (mode = @sig_queue.shift)
        when nil
          kill_runaway_workers
          spawn_workers
        when 'QUIT'
          break
        when 'TERM', 'INT'
          break
        else
          logger.error "master process in unknown mode: #{mode}"
        end
        reap_workers
        ready = IO.select([@rpipe], nil, nil, 1) || next
        ready.first && ready.first.first || next
        @rpipe.read_nonblock(1)
      end
      stop
    end


    private

    def stop
    end

    def reap_workers
      loop do
        pid = Process.waitpid(-1, Process::WNOHANG) || break
        reap_worker(pid)
      end
    rescue Errno::ECHILD
    end

    def reap_worker(pid)
      worker = @workers.delete(pid)
      worker.tempfile.close rescue nil
      logger.info "reaped worker #{worker.number} " \
                  "(PID:#{pid})"
    end

    def kill_runaway_workers
      now = Time.now
      @workers.each_pair do |pid, worker|
        (now - worker.tempfile.ctime) <= Config.timeout && next
        logger.error "worker #{worker.number} (PID:#{pid}) "\
                     "has timed out"
        begin
          Process.kill('KILL', pid)
        rescue Errno::ESRCH
        end
      end
    end

    def spawn_workers
      worker_number = -1
      until (worker_number += 1) == Config.workers
        @workers.value?(worker_number) && next
        tempfile = Tempfile.new('')
        tempfile.unlink
        tempfile.sync = true
        worker = Kaanta::Worker.new(@master_pid, @socket, tempfile, worker_number,logger)
        if pid = fork
          @workers[pid] = worker
        else
          @wpipe.close
          @rpipe.close
          worker.start
        end
      end
    end

    def trap_deferred(signal)
      trap(signal) do |_|
        @sig_queue << signal
        @wpipe.write_nonblock(".")
      end
    end

    def setup_logging
      logger.datetime_format = "%Y-%m-%d %H:%M:%S"
      logger.formatter = proc do |severity, datetime, progname, msg|
        "[#{$PROGRAM_NAME} (PID: #{Process.pid})] #{datetime}: #{severity} -- #{msg}\n"
      end
    end

    def logger
      @logger ||= Logger.new(STDOUT)
    end
  end
end
