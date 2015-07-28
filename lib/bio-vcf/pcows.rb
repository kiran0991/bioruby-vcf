# Parallel copy-on-write streaming (PCOWS)

require 'tempfile'

class PCOWS

  RUNNINGEXT = 'part'
  
  def initialize(num_threads,name=File.basename(__FILE__))
    num_threads = 1 if num_threads==nil # FIXME: set to cpu_num by default
    $stderr.print "Using ",num_threads,"threads \n"
    @num_threads = num_threads
    @pid_list = []
    @name = name
    if multi_threaded
      @tmpdir =  Dir::mktmpdir(@name+'_')
    end
    @last_output = 0 # counter
    @output_locked = nil
  end

  # Feed the worker func and state to COWS. Note that func is a
  # closure so it can pick up surrounding scope at invocation in
  # addition to the data captured in 'state'.
  
  def submit_worker(func,state)
    pid = nil
    if multi_threaded
      count = @pid_list.size+1
      fn = mktmpfilename(count)
      pid = fork do
        # ---- This is running a new copy-on-write process
        tempfn = fn+'.'+RUNNINGEXT
        STDOUT.reopen(File.open(tempfn, 'w+'))
        func.call(state).each { | line | puts line }
        STDOUT.flush
        STDOUT.close
        FileUtils::mv(tempfn,fn)
        exit 0
      end
    else
      # ---- Call in main process
      func.call(state).each { | line | puts line }
    end
    @pid_list << [ pid,count,fn ]
    return true
  end

  # Make sure no more than num_threads are running at the same time -
  # this is achieved by checking the PID table and the running files
  # in the tmpdir

  def wait_for_worker_slot()
    return if not multi_threaded
    while true
      # ---- count running pids
      running = @pid_list.reduce(0) do | sum, info |
        (pid,count,fn) = info
        if pid_or_file_running?(pid,fn)
          sum+1
        else
          sum
        end
      end
      break if running < @num_threads
      $stderr.print "Waiting for slot\n"
      sleep 0.1
    end
  end

  # ---- In this section the output gets collected and passed on to a
  #      printer thread. This function makes sure the printing is
  #      ordered and that no printers are running at the same
  #      time. The printer thread should be doing as little processing
  #      as possible.
  #
  #      In this implementation type==:by_line will call func for
  #      each line. Otherwise it is called once with the filename.

  def process_output(func=nil,type = :by_line)
    return if not multi_threaded
    output = lambda { |fn|
      if type == :by_line
        File.new(fn).each_line { |buf|
          print buf
        }
      else
        func.call(fn)
      end
      File.unlink(fn)
    }
    if @output_locked
      (pid,count,fn) = @output_locked
      return if File.exist?(fn)  # still processing
      # on to the next one
      @last_output += 1
      @output_locked = nil
    end
    if info = @pid_list[@last_output]
      (pid,count,fn) = info
      if File.exist?(fn)
        # Yes! We have the next output, create outputter
        pid = fork do
          output.call(fn)
          exit(0)
        end
        @output_locked = info
      end
    end
  end

  def wait_for_worker(info,timeout=180)
    (pid,count,fn) = info
    if pid_or_file_running?(pid,fn)
      $stderr.print "Waiting up to #{timeout} seconds for pid=#{pid} to complete\n"
      begin
        Timeout.timeout(timeout) do
          while not File.exist?(fn)  # wait for the result to appear
            sleep 0.2
          end
        end
        # Thread file should have gone:
        raise "FATAL: child process appears to have crashed #{fn}" if not File.exist?(fn)
        $stderr.print "OK pid=#{pid}, processing #{fn}\n"
      rescue Timeout::Error
        if pid_running?(pid)
          # Kill it to speed up exit
          Process.kill 9, pid
          Process.wait pid
        end
        $stderr.print "FATAL: child process killed because it stopped responding, pid = #{pid}\n"
      end
    end
  end
  
  # This is the final cleanup after the reader thread is done. All workers
  # need to complete.
  
  def wait_for_workers()
    return if multi_threaded
    @pid_list.each do |info|
      wait_for_worker(info)
    end
  end

  def process_remaining_output()
    return if multi_threaded
    @pid_list.each do |info|
      process_output()
    end
  end
  
  private
  
  def mktmpfilename(num,ext=nil)
    @tmpdir+sprintf("/%0.6d-",num)+@name+(ext ? '.'+ext : '')
  end
  
  def pid_or_file_running?(pid,fn)
    (pid && pid_running?(pid)) or File.exist?(fn+'.'+RUNNINGEXT)
  end
  
  def pid_running?(pid)
    begin
      fpid,status=Process.waitpid2(pid,Process::WNOHANG)
    rescue Errno::ECHILD, Errno::ESRCH
      return false
    end
    return true if nil == fpid && nil == status
    return ! (status.exited? || status.signaled?)
  end

  def multi_threaded
    @num_threads > 1
  end
end