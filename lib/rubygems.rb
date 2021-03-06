# -*- ruby -*-
#--
# Copyright 2006 by Chad Fowler, Rich Kilmer, Jim Weirich and others.
# All rights reserved.
# See LICENSE.txt for permissions.
#++

require 'rubygems/rubygems_version'
require 'rubygems/defaults'
require 'thread'

module Gem
  class LoadError < ::LoadError
    attr_accessor :name, :version_requirement
  end
end

module Kernel

  ##
  # Use Kernel#gem to activate a specific version of +gem_name+.
  #
  # +version_requirements+ is a list of version requirements that the
  # specified gem must match, most commonly "= example.version.number".  See
  # Gem::Requirement for how to specify a version requirement.
  #
  # If you will be activating the latest version of a gem, there is no need to
  # call Kernel#gem, Kernel#require will do the right thing for you.
  #
  # Kernel#gem returns true if the gem was activated, otherwise false.  If the
  # gem could not be found, didn't match the version requirements, or a
  # different version was already activated, an exception will be raised.
  #
  # Kernel#gem should be called *before* any require statements (otherwise
  # RubyGems may load a conflicting library version).
  #
  # In older RubyGems versions, the environment variable GEM_SKIP could be
  # used to skip activation of specified gems, for example to test out changes
  # that haven't been installed yet.  Now RubyGems defers to -I and the
  # RUBYLIB environment variable to skip activation of a gem.
  #
  # Example:
  #
  #   GEM_SKIP=libA:libB ruby -I../libA -I../libB ./mycode.rb

  def gem(gem_name, *version_requirements)
    skip_list = (ENV['GEM_SKIP'] || "").split(/:/)
    raise Gem::LoadError, "skipping #{gem_name}" if skip_list.include? gem_name
    Gem.activate(gem_name, *version_requirements)
  end

end

##
# Main module to hold all RubyGem classes/modules.

module Gem

  ConfigMap = {} unless defined?(ConfigMap)
  require 'rbconfig'
  RbConfig = Config unless defined? ::RbConfig

  ConfigMap.merge!(
    :BASERUBY => RbConfig::CONFIG["BASERUBY"],
    :EXEEXT => RbConfig::CONFIG["EXEEXT"],
    :RUBY_INSTALL_NAME => RbConfig::CONFIG["RUBY_INSTALL_NAME"],
    :RUBY_SO_NAME => RbConfig::CONFIG["RUBY_SO_NAME"],
    :arch => RbConfig::CONFIG["arch"],
    :bindir => RbConfig::CONFIG["bindir"],
    :datadir => RbConfig::CONFIG["datadir"],
    :libdir => RbConfig::CONFIG["libdir"],
    :ruby_install_name => RbConfig::CONFIG["ruby_install_name"],
    :ruby_version => RbConfig::CONFIG["ruby_version"],
    :sitedir => RbConfig::CONFIG["sitedir"],
    :sitelibdir => RbConfig::CONFIG["sitelibdir"],
    :vendordir => RbConfig::CONFIG["vendordir"] ,
    :vendorlibdir => RbConfig::CONFIG["vendorlibdir"]
  )

  DIRECTORIES = %w[cache doc gems specifications] unless defined?(DIRECTORIES)

  MUTEX = Mutex.new

  RubyGemsPackageVersion = RubyGemsVersion

  ##
  # An Array of Regexps that match windows ruby platforms.

  WIN_PATTERNS = [
    /bccwin/i,
    /cygwin/i,
    /djgpp/i,
    /mingw/i,
    /mswin/i,
    /wince/i,
  ]

  @@source_index = nil
  @@win_platform = nil

  @configuration = nil
  @loaded_specs = {}
  @platforms = []
  @ruby = nil
  @sources = []

  @post_install_hooks = []
  @post_uninstall_hooks = []
  @pre_uninstall_hooks = []
  @pre_install_hooks = []

  ##
  # Activates an installed gem matching +gem+.  The gem must satisfy
  # +version_requirements+.
  #
  # Returns true if the gem is activated, false if it is already
  # loaded, or an exception otherwise.
  #
  # Gem#activate adds the library paths in +gem+ to $LOAD_PATH.  Before a Gem
  # is activated its required Gems are activated.  If the version information
  # is omitted, the highest version Gem of the supplied name is loaded.  If a
  # Gem is not found that meets the version requirements or a required Gem is
  # not found, a Gem::LoadError is raised.
  #
  # More information on version requirements can be found in the
  # Gem::Requirement and Gem::Version documentation.

  def self.activate(gem, *version_requirements)
    if version_requirements.empty? then
      version_requirements = Gem::Requirement.default
    end

    unless gem.respond_to?(:name) and
           gem.respond_to?(:version_requirements) then
      gem = Gem::Dependency.new(gem, version_requirements)
    end

    matches = Gem.source_index.find_name(gem.name, gem.version_requirements)
    report_activate_error(gem) if matches.empty?

    if @loaded_specs[gem.name] then
      # This gem is already loaded.  If the currently loaded gem is not in the
      # list of candidate gems, then we have a version conflict.
      existing_spec = @loaded_specs[gem.name]

      unless matches.any? { |spec| spec.version == existing_spec.version } then
        raise Gem::Exception,
              "can't activate #{gem}, already activated #{existing_spec.full_name}"
      end

      return false
    end

    # new load
    spec = matches.last
    return false if spec.loaded?

    spec.loaded = true
    @loaded_specs[spec.name] = spec

    # Load dependent gems first
    spec.runtime_dependencies.each do |dep_gem|
      activate dep_gem
    end

    # bin directory must come before library directories
    spec.require_paths.unshift spec.bindir if spec.bindir

    require_paths = spec.require_paths.map do |path|
      File.join spec.full_gem_path, path
    end

    sitelibdir = ConfigMap[:sitelibdir]

    # gem directories must come after -I and ENV['RUBYLIB']
    insert_index = load_path_insert_index

    if insert_index then
      # gem directories must come after -I and ENV['RUBYLIB']
      $LOAD_PATH.insert(insert_index, *require_paths)
    else
      # we are probably testing in core, -I and RUBYLIB don't apply
      $LOAD_PATH.unshift(*require_paths)
    end

    return true
  end

  ##
  # An Array of all possible load paths for all versions of all gems in the
  # Gem installation.

  def self.all_load_paths
    result = []

    Gem.path.each do |gemdir|
      each_load_path all_partials(gemdir) do |load_path|
        result << load_path
      end
    end

    result
  end

  ##
  # Return all the partial paths in +gemdir+.

  def self.all_partials(gemdir)
    Dir[File.join(gemdir, 'gems/*')]
  end

  private_class_method :all_partials

  ##
  # See if a given gem is available.

  def self.available?(gem, *requirements)
    requirements = Gem::Requirement.default if requirements.empty?

    unless gem.respond_to?(:name) and
           gem.respond_to?(:version_requirements) then
      gem = Gem::Dependency.new gem, requirements
    end

    !Gem.source_index.search(gem).empty?
  end

  ##
  # The mode needed to read a file as straight binary.

  def self.binary_mode
    @binary_mode ||= RUBY_VERSION > '1.9' ? 'rb:ascii-8bit' : 'rb'
  end

  ##
  # The path where gem executables are to be installed.

  def self.bindir(install_dir=Gem.dir)
    return File.join(install_dir, 'bin') unless
      install_dir.to_s == Gem.default_dir
    Gem.default_bindir
  end

  ##
  # Reset the +dir+ and +path+ values.  The next time +dir+ or +path+
  # is requested, the values will be calculated from scratch.  This is
  # mainly used by the unit tests to provide test isolation.

  def self.clear_paths
    @gem_home = nil
    @gem_path = nil
    @@source_index = nil
    MUTEX.synchronize do
      @searcher = nil
    end
  end

  ##
  # The path to standard location of the user's .gemrc file.

  def self.config_file
    File.join Gem.user_home, '.gemrc'
  end

  ##
  # The standard configuration object for gems.

  def self.configuration
    return @configuration if @configuration
    require 'rubygems/config_file'
    @configuration = Gem::ConfigFile.new []
  end

  ##
  # Use the given configuration object (which implements the ConfigFile
  # protocol) as the standard configuration object.

  def self.configuration=(config)
    @configuration = config
  end

  ##
  # The path the the data directory specified by the gem name.  If the
  # package is not available as a gem, return nil.

  def self.datadir(gem_name)
    spec = @loaded_specs[gem_name]
    return nil if spec.nil?
    File.join(spec.full_gem_path, 'data', gem_name)
  end

  ##
  # A Zlib::Deflate.deflate wrapper

  def self.deflate(data)
    Zlib::Deflate.deflate data
  end

  ##
  # The path where gems are to be installed.

  def self.dir
    @gem_home ||= nil
    set_home(ENV['GEM_HOME'] || default_dir) unless @gem_home
    @gem_home
  end

  ##
  # Expand each partial gem path with each of the required paths specified
  # in the Gem spec.  Each expanded path is yielded.

  def self.each_load_path(partials)
    partials.each do |gp|
      base = File.basename(gp)
      specfn = File.join(dir, "specifications", base + ".gemspec")
      if File.exist?(specfn)
        spec = eval(File.read(specfn))
        spec.require_paths.each do |rp|
          yield(File.join(gp, rp))
        end
      else
        filename = File.join(gp, 'lib')
        yield(filename) if File.exist?(filename)
      end
    end
  end

  private_class_method :each_load_path

  ##
  # Quietly ensure the named Gem directory contains all the proper
  # subdirectories.  If we can't create a directory due to a permission
  # problem, then we will silently continue.

  def self.ensure_gem_subdirectories(gemdir)
    require 'fileutils'

    Gem::DIRECTORIES.each do |filename|
      fn = File.join gemdir, filename
      FileUtils.mkdir_p fn rescue nil unless File.exist? fn
    end
  end

  ##
  # Finds the user's home directory.
  #--
  # Some comments from the ruby-talk list regarding finding the home
  # directory:
  #
  #   I have HOME, USERPROFILE and HOMEDRIVE + HOMEPATH. Ruby seems
  #   to be depending on HOME in those code samples. I propose that
  #   it should fallback to USERPROFILE and HOMEDRIVE + HOMEPATH (at
  #   least on Win32).

  def self.find_home
    ['HOME', 'USERPROFILE'].each do |homekey|
      return ENV[homekey] if ENV[homekey]
    end

    if ENV['HOMEDRIVE'] && ENV['HOMEPATH'] then
      return "#{ENV['HOMEDRIVE']}:#{ENV['HOMEPATH']}"
    end

    begin
      File.expand_path("~")
    rescue
      if File::ALT_SEPARATOR then
          "C:/"
      else
          "/"
      end
    end
  end

  private_class_method :find_home

  ##
  # Zlib::GzipReader wrapper that unzips +data+.

  def self.gunzip(data)
    data = StringIO.new data

    Zlib::GzipReader.new(data).read
  end

  ##
  # Zlib::GzipWriter wrapper that zips +data+.

  def self.gzip(data)
    zipped = StringIO.new

    Zlib::GzipWriter.wrap zipped do |io| io.write data end

    zipped.string
  end

  ##
  # A Zlib::Inflate#inflate wrapper

  def self.inflate(data)
    Zlib::Inflate.inflate data
  end

  ##
  # Return a list of all possible load paths for the latest version for all
  # gems in the Gem installation.

  def self.latest_load_paths
    result = []

    Gem.path.each do |gemdir|
      each_load_path(latest_partials(gemdir)) do |load_path|
        result << load_path
      end
    end

    result
  end

  ##
  # Return only the latest partial paths in the given +gemdir+.

  def self.latest_partials(gemdir)
    latest = {}
    all_partials(gemdir).each do |gp|
      base = File.basename(gp)
      if base =~ /(.*)-((\d+\.)*\d+)/ then
        name, version = $1, $2
        ver = Gem::Version.new(version)
        if latest[name].nil? || ver > latest[name][0]
          latest[name] = [ver, gp]
        end
      end
    end
    latest.collect { |k,v| v[1] }
  end

  private_class_method :latest_partials

  ##
  # The index to insert activated gem paths into the $LOAD_PATH.
  #
  # Defaults to the site lib directory unless gem_prelude.rb has loaded paths,
  # then it inserts the activated gem's paths before the gem_prelude.rb paths
  # so you can override the gem_prelude.rb default $LOAD_PATH paths.

  def self.load_path_insert_index
    index = $LOAD_PATH.index ConfigMap[:sitelibdir]

    $LOAD_PATH.each_with_index do |path, i|
      if path.instance_variables.include?(:@gem_prelude_index) or
        path.instance_variables.include?('@gem_prelude_index') then
        index = i
        break
      end
    end

    index
  end

  ##
  # The file name and line number of the caller of the caller of this method.

  def self.location_of_caller
    file, lineno = caller[1].split(':')
    lineno = lineno.to_i
    [file, lineno]
  end

  private_class_method :location_of_caller

  ##
  # manage_gems is useless and deprecated.  Don't call it anymore.
  #--
  # TODO warn w/ RubyGems 1.2.x release.

  def self.manage_gems
    #file, lineno = location_of_caller

    #warn "#{file}:#{lineno}:Warning: Gem#manage_gems is deprecated and will be removed on or after September 2008."
  end

  ##
  # The version of the Marshal format for your Ruby.

  def self.marshal_version
    "#{Marshal::MAJOR_VERSION}.#{Marshal::MINOR_VERSION}"
  end

  ##
  # Array of paths to search for Gems.

  def self.path
    @gem_path ||= nil

    unless @gem_path then
      paths = if ENV['GEM_PATH'] then
                [ENV['GEM_PATH']]
              else
                [default_path]
              end

      if defined?(APPLE_GEM_HOME) and not ENV['GEM_PATH'] then
        paths << APPLE_GEM_HOME
      end

      set_paths paths.compact.join(File::PATH_SEPARATOR)
    end

    @gem_path
  end

  ##
  # Set array of platforms this RubyGems supports (primarily for testing).

  def self.platforms=(platforms)
    @platforms = platforms
  end

  ##
  # Array of platforms this RubyGems supports.

  def self.platforms
    @platforms ||= []
    if @platforms.empty?
      @platforms = [Gem::Platform::RUBY, Gem::Platform.local]
    end
    @platforms
  end

  ##
  # Adds a post-install hook that will be passed an Gem::Installer instance
  # when Gem::Installer#install is called

  def self.post_install(&hook)
    @post_install_hooks << hook
  end

  ##
  # Adds a post-uninstall hook that will be passed a Gem::Uninstaller instance
  # and the spec that was uninstalled when Gem::Uninstaller#uninstall is
  # called

  def self.post_uninstall(&hook)
    @post_uninstall_hooks << hook
  end

  ##
  # Adds a pre-install hook that will be passed an Gem::Installer instance
  # when Gem::Installer#install is called

  def self.pre_install(&hook)
    @pre_install_hooks << hook
  end

  ##
  # Adds a pre-uninstall hook that will be passed an Gem::Uninstaller instance
  # and the spec that will be uninstalled when Gem::Uninstaller#uninstall is
  # called

  def self.pre_uninstall(&hook)
    @pre_uninstall_hooks << hook
  end

  ##
  # The directory prefix this RubyGems was installed at.

  def self.prefix
    prefix = File.dirname File.expand_path(__FILE__)

    if File.dirname(prefix) == File.expand_path(ConfigMap[:sitelibdir]) or
       File.dirname(prefix) == File.expand_path(ConfigMap[:libdir]) or
       'lib' != File.basename(prefix) then
      nil
    else
      File.dirname prefix
    end
  end

  ##
  # Refresh source_index from disk and clear searcher.

  def self.refresh
    source_index.refresh!

    MUTEX.synchronize do
      @searcher = nil
    end
  end

  ##
  # Safely read a file in binary mode on all platforms.

  def self.read_binary(path)
    File.open path, binary_mode do |f| f.read end
  end

  ##
  # Report a load error during activation.  The message of load error
  # depends on whether it was a version mismatch or if there are not gems of
  # any version by the requested name.

  def self.report_activate_error(gem)
    matches = Gem.source_index.find_name(gem.name)

    if matches.empty? then
      error = Gem::LoadError.new(
          "Could not find RubyGem #{gem.name} (#{gem.version_requirements})\n")
    else
      error = Gem::LoadError.new(
          "RubyGem version error: " +
          "#{gem.name}(#{matches.first.version} not #{gem.version_requirements})\n")
    end

    error.name = gem.name
    error.version_requirement = gem.version_requirements
    raise error
  end

  private_class_method :report_activate_error

  def self.required_location(gemname, libfile, *version_constraints)
    version_constraints = Gem::Requirement.default if version_constraints.empty?
    matches = Gem.source_index.find_name(gemname, version_constraints)
    return nil if matches.empty?
    spec = matches.last
    spec.require_paths.each do |path|
      result = File.join(spec.full_gem_path, path, libfile)
      return result if File.exist?(result)
    end
    nil
  end

  ##
  # The path to the running Ruby interpreter.

  def self.ruby
    if @ruby.nil? then
      @ruby = File.join(ConfigMap[:bindir],
                        ConfigMap[:ruby_install_name])
      @ruby << ConfigMap[:EXEEXT]
    end

    @ruby
  end

  ##
  # A Gem::Version for the currently running ruby.

  def self.ruby_version
    return @ruby_version if defined? @ruby_version
    version = RUBY_VERSION.dup
    version << ".#{RUBY_PATCHLEVEL}" if defined? RUBY_PATCHLEVEL
    @ruby_version = Gem::Version.new version
  end

  ##
  # The GemPathSearcher object used to search for matching installed gems.

  def self.searcher
    MUTEX.synchronize do
      @searcher ||= Gem::GemPathSearcher.new
    end
  end

  ##
  # Set the Gem home directory (as reported by Gem.dir).

  def self.set_home(home)
    home = home.gsub(File::ALT_SEPARATOR, File::SEPARATOR) if File::ALT_SEPARATOR
    @gem_home = home
    ensure_gem_subdirectories(@gem_home)
  end

  private_class_method :set_home

  ##
  # Set the Gem search path (as reported by Gem.path).

  def self.set_paths(gpaths)
    if gpaths
      @gem_path = gpaths.split(File::PATH_SEPARATOR)

      if File::ALT_SEPARATOR then
        @gem_path.map! do |path|
          path.gsub File::ALT_SEPARATOR, File::SEPARATOR
        end
      end

      @gem_path << Gem.dir
    else
      # TODO: should this be Gem.default_path instead?
      @gem_path = [Gem.dir]
    end

    @gem_path.uniq!
    @gem_path.each do |gp| ensure_gem_subdirectories(gp) end
  end

  private_class_method :set_paths

  ##
  # Returns the Gem::SourceIndex of specifications that are in the Gem.path

  def self.source_index
    @@source_index ||= SourceIndex.from_installed_gems
  end

  ##
  # Returns an Array of sources to fetch remote gems from.  If the sources
  # list is empty, attempts to load the "sources" gem, then uses
  # default_sources if it is not installed.

  def self.sources
    if @sources.empty? then
      begin
        gem 'sources', '> 0.0.1'
        require 'sources'
      rescue LoadError
        @sources = default_sources
      end
    end

    @sources
  end

  ##
  # Glob pattern for require-able path suffixes.

  def self.suffix_pattern
    @suffix_pattern ||= "{#{suffixes.join(',')}}"
  end

  ##
  # Suffixes for require-able paths.

  def self.suffixes
    ['', '.rb', '.rbw', '.so', '.bundle', '.dll', '.sl', '.jar']
  end

  ##
  # Use the +home+ and +paths+ values for Gem.dir and Gem.path.  Used mainly
  # by the unit tests to provide environment isolation.

  def self.use_paths(home, paths=[])
    clear_paths
    set_home(home) if home
    set_paths(paths.join(File::PATH_SEPARATOR)) if paths
  end

  ##
  # The home directory for the user.

  def self.user_home
    @user_home ||= find_home
  end

  ##
  # Is this a windows platform?

  def self.win_platform?
    if @@win_platform.nil? then
      @@win_platform = !!WIN_PATTERNS.find { |r| RUBY_PLATFORM =~ r }
    end

    @@win_platform
  end

  class << self

    attr_reader :loaded_specs

    ##
    # The list of hooks to be run before Gem::Install#install does any work

    attr_reader :post_install_hooks

    ##
    # The list of hooks to be run before Gem::Uninstall#uninstall does any
    # work

    attr_reader :post_uninstall_hooks

    ##
    # The list of hooks to be run after Gem::Install#install is finished

    attr_reader :pre_install_hooks

    ##
    # The list of hooks to be run after Gem::Uninstall#uninstall is finished

    attr_reader :pre_uninstall_hooks

    # :stopdoc:

    alias cache source_index # an alias for the old name

    # :startdoc:

  end

  MARSHAL_SPEC_DIR = "quick/Marshal.#{Gem.marshal_version}/"

  YAML_SPEC_DIR = 'quick/'

end

module Config
  # :stopdoc:
  class << self
    # Return the path to the data directory associated with the named
    # package.  If the package is loaded as a gem, return the gem
    # specific data directory.  Otherwise return a path to the share
    # area as define by "#{ConfigMap[:datadir]}/#{package_name}".
    def datadir(package_name)
      Gem.datadir(package_name) ||
        File.join(Gem::ConfigMap[:datadir], package_name)
    end
  end
  # :startdoc:
end

require 'rubygems/exceptions'
require 'rubygems/version'
require 'rubygems/requirement'
require 'rubygems/dependency'
require 'rubygems/gem_path_searcher'    # Needed for Kernel#gem
require 'rubygems/source_index'         # Needed for Kernel#gem
require 'rubygems/platform'
require 'rubygems/builder'              # HACK: Needed for rake's package task.

begin
  require 'rubygems/defaults/operating_system'
rescue LoadError
end

if defined?(RUBY_ENGINE) then
  begin
    require "rubygems/defaults/#{RUBY_ENGINE}"
  rescue LoadError
  end
end

if RUBY_VERSION < '1.9' then
  require 'rubygems/custom_require'
end

