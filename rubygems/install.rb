require 'rbconfig'
require 'find'
require 'ftools'

include Config

$srcdir = CONFIG["srcdir"]
$version = CONFIG["MAJOR"]+"."+CONFIG["MINOR"]
$libdir = File.join(CONFIG["libdir"], "ruby", $version)
$archdir = File.join($libdir, CONFIG["arch"])
$site_libdir = $:.find {|x| x =~ /site_ruby$/}
if !$site_libdir
  $site_libdir = File.join($libdir, "site_ruby")
elsif $site_libdir !~ Regexp.quote($version)
  $site_libdir = File.join($site_libdir, $version)
end

def install_rb(srcdir = nil)
  libdir = "lib"
  libdir = File.join(srcdir, libdir) if srcdir
  path = []
  dir = []
  Find.find(libdir) do |f|
    next unless FileTest.file?(f)
    next if (f = f[libdir.length+1..-1]) == nil
    next if (/CVS$/ =~ File.dirname(f))
    path.push f
    dir |= [File.dirname(f)]
  end
  for f in dir
    next if f == "."
    next if f == "CVS"
    File::makedirs(File.join($site_libdir, f))
  end
  for f in path
    File::install(File.join("lib", f), File.join($site_libdir, f), 0644, true)
  end
  gem_dir = File.join(Config::CONFIG['libdir'], 'ruby', 'gems', Config::CONFIG['ruby_version'])
  ["specifications", "cache"].each do |subdir|
    File::makedirs(File.join(gem_dir, subdir))
  end

  Dir.chdir("packages/sources")
    load("sources.gemspec")
    spec = Gem.sources_spec
    Gem::Builder.new(spec).build
    Gem::Installer.new(spec.name + "-" + spec.version.to_s + ".gem").install(true, Gem.dir)
  Dir.chdir("../..")
end

install_rb