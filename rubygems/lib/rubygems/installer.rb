module Gem

  ##
  # The installer class processes RubyGem .gem files and installs
  # the files contained in the .gem into the $GEM_PATH.
  #
  class Installer
  
    ##
    # Constructs a Installer instance
    #
    # gem:: [String] The file name of the gem
    #
    def initialize(gem)
      @gem = gem
    end
    
    ##
    # Installs the gem in the $GEM_PATH.  This will fail (unless force=true)
    # if a Gem has a requirement on another Gem that is not installed.  The
    # installation will install in the following structure:
    #
    #  $GEM_PATH/
    #      specifications/<gem-version>.gemspec #=> the extracted YAML gemspec
    #      <gem-version>/... #=> the extracted Gem files
    #      cache/<gem-version>.gem #=> a cached copy of the installed Gem
    # 
    # force:: [default = false] if false will fail if a required Gem is not installed
    # to_dir:: [default = Gem.dir] directory that Gem is to be installed in
    #
    # return:: [Gem::Specification] The specification for the newly installed Gem.
    #
    def install(force=false, to_dir=Gem.dir)
      require 'fileutils'
      format = Gem::Format.from_file(@gem)
      unless force
         format.spec.dependencies.each do |dep_gem|
           require_gem(dep_gem)
         end
       end
       #build spec dir
       directory = File.join(to_dir, format.spec.full_name)
       FileUtils.mkdir_p directory
       extract_files(directory, format)
       
       #build spec/cache/doc dir
       unless File.exist? File.join(to_dir, "specifications")
         FileUtils.mkdir_p File.join(to_dir, "specifications")
       end
       unless File.exist? File.join(to_dir, "cache")
         FileUtils.mkdir_p File.join(to_dir, "cache")
       end
       unless File.exist? File.join(to_dir, "doc")
         FileUtils.mkdir_p File.join(to_dir, "doc")
       end
       
       write_spec(format.spec, File.join(to_dir, "specifications"))
       
       FileUtils.cp(@gem, File.join(to_dir, "cache"))
       
       puts "Successfully installed #{format.spec.name} version #{format.spec.version}"
       format.spec.loaded_from = File.join(to_dir, 'specifications', format.spec.full_name+".gemspec")
       return format.spec
    end
    
    ##
    # Writes the .gemspec specification (in Ruby) to the supplied spec_path.
    #
    # spec:: [Gem::Specification] The Gem specification to output
    # spec_path:: [String] The location (path) to write the gemspec to
    #
    def write_spec(spec, spec_path)
      File.open(File.join(spec_path, spec.full_name+".gemspec"), "w") do |file|
        file.puts spec.to_ruby
      end
    end
    
    ##
    # Reads the YAML file index and then extracts each file
    # into the supplied directory, building directories for the
    # extracted files as needed.
    #
    # directory:: [String] The root directory to extract files into
    # file:: [IO] The IO that contains the file data
    #
    def extract_files(directory, format)
      require 'fileutils'
      wd = Dir.getwd
      Dir.chdir directory
      begin
        format.file_entries.each do |entry, file_data|
          path = entry['path']
          mode = entry['mode']
          FileUtils.mkdir_p File.dirname(path)
          File.open(path, "wb") do |out|
            out.write file_data
          end
        end
      ensure
        Dir.chdir wd
      end
    end
  end

  
  ##
  # The Uninstaller class uninstalls a Gem
  #
  class Uninstaller
  
    ##
    # Constructs and Uninstaller instance
    # 
    # gem:: [String] The Gem name to uninstall
    #
    def initialize(gem, version="> 0")
      @gem = gem
      @version = version
    end
    
    ##
    # Performs the uninstall of the Gem.  This removes the spec, the Gem
    # directory, and the cached .gem file.
    #
    def uninstall
      require 'fileutils'
      cache = Cache.from_installed_gems
      list = cache.search(@gem, @version)
      if list.size == 0 
        puts "Unknown RubyGem: #{@gem}-#{@version}"
      elsif list.size>1
        puts "Select RubyGem to uninstall:"
        list.each_with_index do |gem, index|
          puts " #{index+1}. #{gem.full_name}"
        end
        puts " #{list.size+1}. All versions"
        print "> "
        response = gets.strip.to_i - 1
        if response == list.size
          list.each {|gem| remove(gem)}
        elsif response < list.size
          remove(list[response])
        else
          puts "Error: must enter a number [1-#{list.size+1}]"
        end
      else
        remove(list[0])
      end
    end
    
    
    def remove(spec)
      FileUtils.rm_rf spec.full_gem_path
      FileUtils.rm_rf File.join(spec.installation_path, 'specifications', "#{spec.full_name}.gemspec")
      FileUtils.rm_rf File.join(spec.installation_path, 'cache', "#{spec.full_name}.gem")
      DocManager.new(spec).uninstall_doc
      puts "Successfully uninstalled #{spec.name} version #{spec.version}"
    end
  end
  
end