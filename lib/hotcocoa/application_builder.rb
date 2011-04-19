framework 'Foundation'

require 'fileutils'
require 'rbconfig'
require 'yaml'

module HotCocoa
  class ApplicationBuilder
    class Configuration
      attr_reader :name, :identifier, :version, :icon, :resources, :sources
      attr_reader :info_string, :agent, :stdlib, :data_models

      def initialize(file)
        yml = YAML.load(File.read(file))
        @name = yml["name"]
        @identifier = yml["identifier"]
        @version = yml["version"] || "1.0"
        @icon = yml["icon"]
        @info_string = yml["info_string"]
        @sources = yml["sources"] || []
        @resources = yml["resources"] || []
        @data_models = yml["data_models"] || []
        @overwrite = yml["overwrite"] == true ? true : false
        @agent = yml["agent"] == true ? "1" : "0"
        @stdlib = yml["stdlib"] == false ? false : true
      end

      def overwrite?
        @overwrite
      end

      def icon_exist?
        @icon ? File.exist?(@icon) : false
      end
    end

    ApplicationBundlePackage = "APPL????"

    attr_accessor :name, :identifier, :sources, :overwrite, :icon
    attr_accessor :version, :info_string, :resources, :deploy, :agent, :stdlib, :data_models

    def self.build(config, options={:deploy => false})
      if !config.kind_of?(Configuration) || !$LOADED_FEATURES.detect {|f| f.include?("standard_rake_tasks")}
        puts "Your Rakefile needs to be updated.  Please copy the Rakefile from:"
        puts File.expand_path(File.join(Config::CONFIG['datadir'], "hotcocoa_template", "Rakefile"))
        exit
      end

      builder = new
      builder.deploy = options[:deploy] == true ? true : false
      builder.name = config.name
      builder.identifier = config.identifier
      builder.icon = config.icon if config.icon_exist?
      builder.version = config.version
      builder.info_string = config.info_string
      builder.overwrite = config.overwrite?
      builder.agent = config.agent
      builder.stdlib = config.stdlib

      config.sources.each { |source| builder.add_source_path(source) }
      config.resources.each { |resource| builder.add_resource_path(resource) }
      config.data_models.each do |data|
        next unless File.extname(data) == ".xcdatamodel"
        builder.add_data_model(data)
      end

      builder.build
    end

    # Used by the "Embed MacRuby" Xcode target.
    def self.deploy(path)
      raise "Given path `#{path}' does not exist" unless File.exist?(path)
      raise "Given path `#{path}' does not look like an application bundle" unless File.extname(path) == '.app'

      deployer = new
      Dir.chdir(File.dirname(path)) do
        deployer.name = File.basename(path, '.app')
        deployer.deploy
      end
    end

    def initialize
      @sources = []
      @resources = []
      @data_models = []
    end

    def build
      check_for_bundle_root
      build_bundle_structure
      write_bundle_files
      copy_sources
      copy_resources
      compile_data_models
      deploy if deploy?
      copy_icon_file if icon
    end

    def deploy
      copy_framework
      copy_hotcocoa unless stdlib
    end

    def deploy?
      @deploy
    end

    def overwrite?
      @overwrite
    end

    def add_source_path(source_file_pattern)
      Dir.glob(source_file_pattern).each do |source_file|
        sources << source_file
      end
    end

    def add_resource_path(resource_file_pattern)
      Dir.glob(resource_file_pattern).each do |resource_file|
        resources << resource_file
      end
    end

    def add_data_model(model)
      Dir.glob(model).each { |data| data_models << data }
    end

    private

    def check_for_bundle_root
      if File.exist?(bundle_root) && overwrite?
        `rm -rf #{bundle_root}`
      end
    end

    def build_bundle_structure
      [bundle_root, contents_root, frameworks_root,
       macos_root, resources_root].each do |dir|
        Dir.mkdir(dir) unless File.exist?(dir)
      end
    end

    def write_bundle_files
      write_pkg_info_file
      write_info_plist_file
      build_executable unless File.exist?(File.join(macos_root, objective_c_executable_file))
      write_ruby_main
    end

    def copy_framework
      `macruby_deploy --embed #{name}.app #{ '--no-stdlib' unless stdlib }`
    end

    def copy_hotcocoa
      `macgem unpack hotcocoa`
      Dir.glob("hotcocoa-*/lib/*").each do |source|
        destination = File.join(resources_root, source.split('/').last)
        FileUtils.mkdir_p(File.dirname(destination)) unless File.exist?(File.dirname(destination))
        FileUtils.cp_r source, destination
      end
      FileUtils.rm_rf Dir.glob("hotcocoa-*").first
    end

    def copy_sources
      sources.each do |source|
        destination = File.join(resources_root, source)
        FileUtils.mkdir_p(File.dirname(destination)) unless File.exist?(File.dirname(destination))
        FileUtils.cp_r source, destination
      end
    end

    def copy_resources
      resources.each do |resource|
        destination = File.join(resources_root, resource.split("/")[1..-1].join("/"))
        FileUtils.mkdir_p(File.dirname(destination)) unless File.exist?(File.dirname(destination))

        if resource =~ /\.xib$/
          destination.gsub!(/.xib/, '.nib')
          puts `ibtool --compile #{destination} #{resource}`
        else
          FileUtils.cp_r(resource, destination)
        end
      end
    end

    def compile_data_models
      data_models.each do |data|
        `/Developer/usr/bin/momc #{data} #{resources_root}/#{File.basename(data, ".xcdatamodel")}.mom`
      end
    end

    def copy_icon_file
      FileUtils.cp(icon, icon_file) unless File.exist?(icon_file)
    end

    def write_pkg_info_file
      File.open(pkg_info_file, "wb") {|f| f.write ApplicationBundlePackage}
    end

    def write_info_plist_file
      File.open(info_plist_file, "w") do |f|
        f.puts %{<?xml version="1.0" encoding="UTF-8"?>}
        f.puts %{<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">}
        f.puts %{<plist version="1.0">}
        f.puts %{<dict>}
        f.puts %{  <key>CFBundleDevelopmentRegion</key>}
        f.puts %{  <string>English</string>}
        f.puts %{  <key>CFBundleIconFile</key>} if icon
        f.puts %{  <string>#{name}.icns</string>} if icon
        f.puts %{  <key>CFBundleGetInfoString</key>} if info_string
        f.puts %{  <string>#{info_string}</string>} if info_string
        f.puts %{  <key>CFBundleExecutable</key>}
        f.puts %{  <string>#{name.gsub(/ /, '')}</string>}
        f.puts %{  <key>CFBundleIdentifier</key>}
        f.puts %{  <string>#{identifier}</string>}
        f.puts %{  <key>CFBundleInfoDictionaryVersion</key>}
        f.puts %{  <string>6.0</string>}
        f.puts %{  <key>CFBundleName</key>}
        f.puts %{  <string>#{name}</string>}
        f.puts %{  <key>CFBundlePackageType</key>}
        f.puts %{  <string>APPL</string>}
        f.puts %{  <key>CFBundleSignature</key>}
        f.puts %{  <string>????</string>}
        f.puts %{  <key>CFBundleVersion</key>}
        f.puts %{  <string>#{version}</string>}
        f.puts %{  <key>NSPrincipalClass</key>}
        f.puts %{  <string>NSApplication</string>}
        f.puts %{  <key>LSUIElement</key>}
        f.puts %{  <string>#{agent}</string>}
        f.puts %{</dict>}
        f.puts %{</plist>}
      end
    end

    def build_executable
      File.open(objective_c_source_file, "wb") do |f|
        f.puts %{
          #import <MacRuby/MacRuby.h>

          int main(int argc, char *argv[])
          {
              return macruby_main("rb_main.rb", argc, argv);
          }
        }
      end
      archs = RUBY_ARCH.include?('ppc') ? '-arch ppc' : '-arch i386 -arch x86_64'
      puts `cd "#{macos_root}" && gcc main.m -o #{objective_c_executable_file} #{archs} -framework MacRuby -framework Foundation -fobjc-gc-only`
      File.unlink(objective_c_source_file)
    end

    def write_ruby_main
      File.open(main_ruby_source_file, "wb") do |f|
        f.puts "$:.map! { |x| x.sub(/^\\/Library\\/Frameworks/, NSBundle.mainBundle.privateFrameworksPath) }" if deploy?
        f.puts "resources = NSBundle.mainBundle.resourcePath.fileSystemRepresentation"
        f.puts "$:.unshift(resources)"
        f.puts
        f.puts "Dir.glob(\"\#{resources}/**/*.rb\").each do |file|"
        f.puts "  next if file == 'rb_main.rb'"
        f.puts "  require \"\#{file}\""
        f.puts "end"
        f.puts
        f.puts "begin"
        f.puts "  Kernel.const_get('#{name}').new.start"
        f.puts "rescue Exception => e"
        f.puts "  STDERR.puts e.message"
        f.puts "  e.backtrace.each { |bt| STDERR.puts bt }"
        f.puts "end"
      end
    end

    def bundle_root
      "#{name}.app"
    end

    def contents_root
      File.join(bundle_root, "Contents")
    end

    def frameworks_root
      File.join(contents_root, "Frameworks")
    end

    def macos_root
      File.join(contents_root, "MacOS")
    end

    def resources_root
      File.join(contents_root, "Resources")
    end

    def bridgesupport_root
      File.join(resources_root, "BridgeSupport")
    end

    def info_plist_file
      File.join(contents_root, "Info.plist")
    end

    def icon_file
      File.join(resources_root, "#{name}.icns")
    end

    def pkg_info_file
      File.join(contents_root, "PkgInfo")
    end

    def objective_c_executable_file
      name.gsub(/ /, '')
    end

    def objective_c_source_file
      File.join(macos_root, "main.m")
    end

    def main_ruby_source_file
      File.join(resources_root, "rb_main.rb")
    end

    def current_macruby_version
      NSFileManager.defaultManager.pathContentOfSymbolicLinkAtPath(File.join(macruby_versions_path, "Current"))
    end

    def current_macruby_path
      File.join(macruby_versions_path, current_macruby_version)
    end

    def macruby_versions_path
      File.join(macruby_framework_path, "Versions")
    end

    def macruby_framework_path
      "/Library/Frameworks/MacRuby.framework"
    end
  end
end
