#Sketchup::require("moosas2018/src/MoosasConstant")

require 'fileutils' unless defined?(FileUtils)
require 'thread' unless defined?(Queue)

# if Sketchup.version.to_f >= 14

# 	begin
# 		require 'net/https'
# 	rescue LoadError => e
# 		MoosasUtils.log_error(e)
# 	end

# 	begin
# 		require 'uri'
# 		require 'open-uri' #using open-uri since it follows redirects properly, and has a simpler interface
# 	rescue LoadError => e
# 		MoosasUtils.log_error(e)
# 	end
# end

class MoosasUtils
	Ver='0.6.4'

	def self.is_unix()
	# Function:
	# Determines whether the current platform is a Unix-based system.
	# 
	# Parameters:
	# None
	# 
	# Returns:
	# bool: Returns true if the current RUBY_PLATFORM matches a Unix-like system
	# (including darwin, linux, i386-cygwin, or i386-mingw32), otherwise false.
	# Note: The method uses a case-insensitive regular expression check and
	# returns true only if the match result is exactly 1, which may indicate
	# a logic issue since regex match results are typically indices or nil.
		( RUBY_PLATFORM =~ /(darwin|linux|i386-cygwin|i386-mingw32)/i ) == 1
	end

	def self.moosas_active?
		MoosasWebDialog.dialog.visible?
	end
    def self.exec_python(pyfile, codelines, console=true)
        require 'tmpdir'
        require 'json'
        parent = File.join(MPath::DATA, 'jobs')
        FileUtils.mkdir_p(parent)
        directory = Dir.mktmpdir(File.basename(pyfile, '.*') + '-', parent)
        script_path = File.join(directory, 'run.py')
        script = ["import sys, os, tempfile", "os.makedirs('tmp', exist_ok=True)",
            "tempfile.tempdir = os.path.abspath('tmp')", "sys.path.insert(0, #{MPath::PYTHON_ROOT.to_json})"]
        output = File.join(directory, 'stdout.log')
        script += ['from skp.scripts.console_job import install_log', "install_log(#{output.to_json})"] if console
        script += codelines
        File.write(script_path, script.join("\n"), encoding: 'UTF-8')
        output = File.join(directory, 'stdout.log')
        args = console ? [File.join(MPath::SCRIPTS, 'console_job.py'), script_path] : [script_path]
        success = system(File.join(MPath::PYTHON, 'python.exe'), '-u', *args,
            chdir: directory, out: output, err: [:child, :out])
        File.write(File.join(directory, 'process.json'), JSON.generate({'success'=>!!success}), encoding:'UTF-8')
        p File.read(output, encoding:'UTF-8') unless success
        !!success
    rescue => e
        p "Python job failed: #{e.message}"
        false
    end

	def self.exec_python_async(pyfile, codelines, workspace: nil, console: false, &on_complete)
        require 'tmpdir'
        require 'json'
        require 'fileutils'
        jobs = File.join(MPath::DATA, 'jobs')
        FileUtils.mkdir_p(jobs)
          workspace ||= Dir.mktmpdir(File.basename(pyfile, '.*') + '-', jobs)
          FileUtils.mkdir_p(workspace)
        script_path = File.join(workspace, 'run.py')
        output_path = File.join(workspace, 'stdout.log')
        script = ["import sys, os, tempfile", "os.makedirs('tmp', exist_ok=True)", "tempfile.tempdir = os.path.abspath('tmp')",
                  "sys.path.insert(0, #{MPath::PYTHON_ROOT.to_json})"]
        script += console ? ['from skp.scripts.console_job import install_log', "install_log(#{output_path.to_json})"] :
                  ["sys.stdout = open(#{output_path.to_json}, 'a', encoding='utf-8', buffering=1)", "sys.stderr = sys.stdout"]
        script += ["print('Moosas Python job started', flush=True)"] + codelines
        File.write(script_path, script.join("\n"), :encoding => 'UTF-8')
        args = console ? [File.join(MPath::SCRIPTS, 'console_job.py'), script_path] : [script_path]
        pid = Process.spawn(File.join(MPath::PYTHON, 'python.exe'), '-u', *args,
                            :chdir => workspace, :out => output_path, :err => [:child, :out])
        poll = nil
        poll = proc do
            finished = nil
            begin
                finished = Process.waitpid2(pid, Process::WNOHANG)
            rescue Errno::ECHILD
                finished = [pid, nil]
            end
              if finished
                  success = finished[1] && finished[1].success?
                  File.write(File.join(workspace, 'process.json'), JSON.generate({
                    'pid'=>pid, 'success'=>!!success, 'exitstatus'=>finished[1]&.exitstatus,
                    'status'=>finished[1].to_s
                  }), :encoding=>'UTF-8')
                p "Python job #{success ? 'complete' : 'failed'}: #{workspace}"
                if !success && File.file?(output_path)
                    File.open(output_path, 'rb') do |log|
                        log.seek([log.size - 16000, 0].max)
                        print log.read
                    end
                end
                begin
                    on_complete.call(!!success) if on_complete
                rescue Exception => e
                    p "Python completion callback failed: #{e.class}: #{e.message}"
                    p e.backtrace.join("\n")
                end
            else
                UI.start_timer(0.2, false, &poll)
            end
        end
        UI.start_timer(0.2, false, &poll)
        true
    rescue Exception => e
        p "Could not start Python job: #{e.class}: #{e.message}"
        false
    end
	def self.rescue_log(e, log_to_sconsole=true)
	# """
	# Function
	# --------
	# Handles exception logging and model operation abortion in SketchUp environment.
	# 
	# Parameters
	# ----------
	# e : Exception
	# The exception object to be logged.
	# log_to_sconsole : bool, optional
	# If true, logs the error message to SketchUp's Ruby console. Default is True.
	# 
	# Returns
	# -------
	# None
	# This method does not return a value. It performs side effects including operation abortion and error logging.
	# """
	    if (defined?(Sketchup.active_model) and not Sketchup.active_model.nil?)
	      Sketchup.active_model.abort_operation
	    end
	    MoosasUtils.log_error(e, log_to_sconsole)
	end

	def self.log_error(e, log_to_sconsole=true)
	# """
	# Function
	# --------
	# Logs an error message or exception to the system console or log system.
	# 
	# Parameters
	# ----------
	# e : Exception or String
	# The exception object or error message to be logged. If it is an Exception
	# with a backtrace, the formatted exception including stack trace will be logged.
	# Otherwise, the string representation of the error will be logged.
	# log_to_sconsole : bool, optional
	# If True (default), logs the error to the system console. This parameter
	# does not directly affect logging behavior in this method but may be used
	# in downstream `self.log` implementation to route output.
	# 
	# Returns
	# -------
	# None
	# This method does not return a value. It performs a side effect by writing
	# error information to the log.
	# """
	 	if defined?(e.backtrace)
	      self.log(self.format_error(e))
	    else
	      self.log("error: " + e)
	    end
	end

	def self.format_error(e)
	# Function:
	# Format an exception into a standardized error message string.
	# 
	# Parameters:
	# e : Exception
	# The exception object to be formatted. It should have `inspect` and `backtrace` methods available,
	# typically an instance of a Ruby Exception class or its descendants.
	# 
	# Returns:
	# str
	# A formatted string containing the error message and backtrace. The message includes the inspected
	# exception value and the full backtrace indented and joined with newline characters for readability.
		error_backtrace = e.backtrace.join("\n                            ")
    	"error: message='#{e.inspect}', backtrace='#{error_backtrace}'"
  	end

	def self.log(string)
	# Function:
	# Logs a given string with a timestamp to the console.
	# 
	# Parameters:
	# string : str
	# The message to be logged. It will be prefixed with the current time in ASCII format.
	# 
	# Returns:
	# None
	# This method does not return a value. It outputs the log line to standard output (console).
	 	log_line = Time.now.asctime+"\t"+string+"\n"
    	puts log_line
	end

	def self.get_path()
	# """
	# Function
	# --------
	# Returns the parent directory path of the current file's directory.
	# 
	# Parameters
	# ----------
	# None
	# 
	# Returns
	# -------
	# str
	# The absolute path to the parent directory of the directory containing the current file.
	# """
		File.dirname(__FILE__) + "/../"
	end

	def self.upload_file(url, filename)
	# """
	# Function
	# ----------
	# Uploads the content of a local file to a specified URL using an HTTP GET request with the file data in the body.
	# 
	# Parameters
	# ----------
	# url : str
	# The destination URL to which the file will be uploaded. Must include the scheme (http or https).
	# filename : str
	# The path to the local file that is to be uploaded. The file is read in binary mode.
	# 
	# Returns
	# -------
	# response : Net::HTTPResponse
	# The HTTP response object returned by the server after the request is made. This includes status code, headers, and body.
	# """
		uri = URI.parse(url)

    	http = Net::HTTP.new(uri.host, uri.port)
    	http.use_ssl = (uri.scheme == 'https')
    	http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    	request = Net::HTTP::Get.new(uri.request_uri, {"Content-Type" => "application/octet-stream"})
    	request.body = File.open(filename, 'rb').read
    	response = http.request(request)
    	return response
	end

	def self.download_file(url, filename)
	# """
	# Function
	# ----------
	# Download a file from the specified URL and save it locally with the given filename.
	# 
	# Parameters
	# ----------
	# url : str
	# The URL of the file to be downloaded. Must be a valid HTTP or HTTPS address.
	# filename : str
	# The local path and name under which the downloaded file will be saved.
	# 
	# Returns
	# -------
	# None
	# This method does not return a value. It saves the downloaded content directly to the specified file.
	# """
		open(url,:ssl_verify_mode => OpenSSL::SSL::VERIFY_NONE,"Content-Type" => "application/octet-stream") { |f|
      		File.open(filename, 'wb') do |file|
        		file.puts f.read
      		end
    	}
	end

	def self.get_document_dir()
	# """
	# Function
	# --------
	# Get the document directory path for the application, creating it if it does not exist.
	# 
	# On Unix-like systems, the directory is created under the user's home folder as '~/Moosas/'.
	# On Windows, it retrieves the user's personal documents folder from the registry and appends 'Moosas'.
	# 
	# Parameters
	# ----------
	# None
	# This method does not accept any parameters.
	# 
	# Returns
	# -------
	# String or nil
	# The file path to the document directory (e.g., '~/Moosas' or 'C:/Users/User/Documents/Moosas').
	# Returns nil if an exception occurs during execution.
	# """
		begin
			if(!@documents_dir)
				if(is_unix())
					@documents_dir = File.expand_path('~/Moosas/')
				else
					require 'win32/registry'
					reg_path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
        			reg = Win32::Registry::HKEY_CURRENT_USER.open( reg_path )
        			dir = File.expand_path(reg['Personal'])
        			@documents_dir = File.join(dir, "Moosas")
				end
			end

			Dir.mkdir(@documents_dir,(0777 & ~File.umask)) unless File.exists?(@documents_dir)

			return @documents_dir

		rescue Exception => e
			rescue_log(e)
		end
	end

	def self.get_temp_dir()
	# """
	# Function
	# --------
	# get_temp_dir : class method
	# Returns the path to a temporary directory used by the application.
	# If the directory does not exist, it is created automatically.
	# 
	# Parameters
	# ----------
	# None
	# This method does not accept any parameters.
	# 
	# Returns
	# -------
	# str
	# The file system path to the temporary directory. On Unix-like systems,
	# this is '/tmp/Moosas/'. On Windows, it is a 'Moosas' subdirectory
	# within the system's TEMP directory.
	# """
		if(is_unix())
			temp = "/tmp/Moosas/"
		else
			temp = File.join(File.expand_path(ENV["TEMP"]), "Moosas")
		end

		Dir.mkdir(temp) unless File.exists?(temp)

		return temp
	end

    def self.get_flat_plane
    # Function:
    # Extracts selected faces from the active SketchUp model and projects them onto the XY plane (Z=0)
    # by creating a new group containing flattened versions of the original faces.
    # 
    # Parameters:
    # None
    # 
    # Returns:
    # nil : The method does not return any value. It modifies the model by adding a new group
    # with projected 2D faces on the XY plane.
    # 
    # Notes:
    # - Operates on the current selection in the active model.
    # - Only processes entities that are instances of Sketchup::Face.
    # - Each vertex of the selected face is projected onto the XY plane (defined by origin and Z-axis normal).
    # - A new face is created in a group using the projected 2D points.
    # - Prints each entity and a progress message for every processed face.

        model  = Sketchup.active_model
        sel = model.selection
        oxy_plane = [Geom::Point3d.new(0,0,0), Geom::Vector3d.new(0,0,1)]

        group = Sketchup.active_model.entities.add_group
        entities = group.entities
        i = 0
        sel.each do |entity|
            p entity
            case entity
            when Sketchup::Face
                ol = entity.outer_loop
                vertices = ol.vertices
                vs = []
                vertices.each do |v|
                    vs.push v.position.project_to_plane(oxy_plane)
                end
                entities.add_face vs
                i += 1
                p "添加了#{i}个面"
            end
        end
    end
    def self.settings_path
        require 'digest'
        require 'json'
        model = Sketchup.active_model
        identity = model.path.to_s.empty? ? model.guid : File.expand_path(model.path)
        directory = File.join(MPath::DATA, 'settings')
        FileUtils.mkdir_p(directory)
        path = File.join(directory, Digest::SHA256.hexdigest(identity) + '.json')
        unless File.file?(path)
            legacy = File.join(MPath::DB, 'settings', model.title + '.json')
            values = File.file?(legacy) ? JSON.parse(File.read(legacy, encoding: 'UTF-8')) : {}
            spaces = values.to_h { |id, data| [id, {'values'=>data, 'explicit'=>[], 'legacy'=>true}] }
            File.write(path, JSON.generate({'schema_version'=>2, 'revision'=>0, 'spaces'=>spaces}), encoding: 'UTF-8')
        end
        path
    end

    def self.settings_document
        JSON.parse(File.read(settings_path, encoding: 'UTF-8'))
    end

    def self.retrive_setting_data
        data = settings_document['spaces']
        $current_model.spaces.each do |space|
            saved = data[space.id.to_s]
            next unless saved
            values = saved['values'].dup
            values['zone_infiltration'] ||= values.delete('zone_inflitration') if values.key?('zone_inflitration')
            values.delete('zone_inflitration')
            space.settings.merge!(values)
            space.instance_variable_set(:@explicit_settings, saved['explicit'] || [])
            space.instance_variable_set(:@main_settings_legacy, !!saved['legacy'])
        end
    end

    def self.backup_setting_data(space_id = nil)
        path = settings_path
        data = settings_document
        $current_model.spaces.each do |space|
            next if space_id && space.id != space_id
            previous = data['spaces'][space.id.to_s] || {}
            data['spaces'][space.id.to_s] = previous.merge('values'=>space.settings,
                'explicit'=>Array(space.instance_variable_get(:@explicit_settings)))
        end
        temporary = path + '.tmp'
        File.write(temporary, JSON.generate(data), encoding: 'UTF-8')
        File.rename(temporary, path)
    end
    def self.wait(file,max_waiting=10)
    # """
    # Function
    # --------
    # Waits for a specified file to become available within a given time limit.
    # 
    # This method repeatedly checks for the existence of a file at half-second intervals
    # up to a maximum number of attempts. It prints a message each time the file is not found
    # and returns early if the file is detected before the timeout.
    # 
    # Parameters
    # ----------
    # file : String
    # The path to the file whose existence is being checked.
    # max_waiting : Integer, optional
    # The maximum number of half-second intervals to wait (default is 10, i.e., 5 seconds).
    # 
    # Returns
    # -------
    # Boolean
    # Returns `true` if the file is found within the waiting period.
    # If the file is not found after `max_waiting` attempts, the method ends without an explicit return,
    # which results in `nil` being returned by default.
    # """
    	(1..max_waiting).each{ |variable|  
	    	if File.exists? file
	    		return true
	    	else
	    		p "**Error: Unfound " + file + " Waiting..." + variable.to_s
	    		sleep(0.5)
	    	end
    	}
    end

    def self.back_up_model()
    # Function:
    # Creates a backup copy of the active SketchUp model with a timestamped filename.
    # If the model is already saved, it uses the original path and model title to construct
    # the backup filename. Otherwise, saves the backup to the user's Desktop with a default name.
    # 
    # Parameters:
    # None
    # 
    # Returns:
    # str or None: The file path of the saved backup copy if successful; None if the save operation
    # fails or an exception occurs (e.g., model has not been saved yet). Prints an error message
    # to stdout if the model cannot be backed up due to being unsaved.
        model = Sketchup.active_model
        path = model.path
        fn = Time.new
        fn = fn.to_s
        fn = fn[0,19].gsub(":","_").gsub(" ","_")

        title =  model.title
        if path != nil and path != "" and title != nil and title !=""
            arr = path.split("\\")
            arr[arr.length-1] = "#{title}_#{fn}.skp"
            filename = arr.join("\\")
        else
            filename = File.join(ENV['Home'], 'Desktop', "MOOSAS模型#{fn}.skp")
        end


        begin
            status = model.save_copy(filename)
            if status == true
                return filename
            else
                return nil
            end
        rescue Exception => e
            p "请先保存模型，才能进行模型备份!"
            return nil
        end
    end

end
