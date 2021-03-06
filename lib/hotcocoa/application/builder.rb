framework 'Foundation'

require 'fileutils'
require 'rbconfig'
require 'hotcocoa/application/specification'

module Application
  ##
  # This class is responsible for building application bundles, but could
  # theoretically be used to build other bundles, such as frameworks, with
  # only a few changes.
  class Builder

    ##
    # Build an application from a specification, optionally for
    # deployment.
    #
    # @param [Application::Specification] spec
    # @param [Hash] opts
    # @option opts [Symbol] :deploy (false)
    def self.build spec, opts = {}
      new(spec).build(opts)
    end

    # @return [Application::Specification]
    attr_reader :spec

    # @param [Application::Specification]
    def initialize spec
      @spec = case spec
      when Specification
        spec
      when String
        Specification.load spec
      end
    end

    # @param [Hash]
    # @option opts [Symbol] :deploy (false)
    def build opts = {}
      if spec.overwrite? || opts[:deploy] # Deploying always makes a fresh build
        remove_bundle_root
      end
      build_bundle_structure
      write_bundle_files
      copy_sources
      copy_resources
      compile_data_models
      copy_icon_file if spec.icon_exists?
      deploy if opts[:deploy]
    end

    def run
      `"./#{executable_file}"`
    end

    def remove_bundle_root
      FileUtils.rm_rf bundle_root if File.exist?(bundle_root)
    end


    private

    ##
    # Build arguments list and call to `macruby_deploy`.
    def deploy
      options = []
      spec.gems.each { |g| options << "--gem #{g.name}" }
      options << '--bs'        if spec.embed_bs?
      options << '--compile'   if spec.compile?
      options << '--no-stdlib' unless spec.stdlib # @todo use attribute properly
      options = options.join(' ')
      puts `macruby_deploy --embed --gem hotcocoa #{options} #{bundle_root}`
    end

    def build_bundle_structure
      [bundle_root, contents_root, frameworks_root, macos_root, resources_root].each do |dir|
        Dir.mkdir(dir) unless File.exist?(dir)
      end
    end

    def write_bundle_files
      write_pkg_info_file
      write_info_plist_file
      build_executable unless File.exist?(executable_file)
      write_ruby_main
    end

    def copy_sources
      spec.sources.each do |source|
        destination = File.join(resources_root, source)
        FileUtils.mkdir_p(File.dirname(destination)) unless File.exist?(File.dirname(destination))
        FileUtils.cp_r source, destination
      end
    end

    def copy_resources
      spec.resources.each do |resource|
        destination = File.join(resources_root, resource.split('/')[1..-1].join('/'))
        FileUtils.mkdir_p(File.dirname(destination)) unless File.exist?(File.dirname(destination))

        if resource =~ /\.xib$/
          destination.gsub!(/.xib/, '.nib')
          puts `ibtool --compile #{destination} #{resource}`
        else
          FileUtils.cp_r resource, destination
        end
      end
    end

    def compile_data_models
      spec.data_models.each do |data|
        `/Developer/usr/bin/momc #{data} #{resources_root}/#{File.basename(data, ".xcdatamodel")}.mom`
      end
    end

    def copy_icon_file
      FileUtils.cp spec.icon, icon_file
    end

    def write_pkg_info_file
      File.open(pkg_info_file, 'wb') { |f| f.write "#{spec.type}#{spec.signature}" }
    end

    def write_info_plist_file
      # http://developer.apple.com/library/mac/#documentation/General/Reference/InfoPlistKeyReference/Articles/AboutInformationPropertyListFiles.html%23//apple_ref/doc/uid/TP40009254-SW1
      info = {
        CFBundleName:                  spec.name,
        CFBundleIdentifier:            spec.identifier,
        CFBundleVersion:               spec.version,
        CFBundlePackageType:           spec.type,
        CFBundleSignature:             spec.signature,
        CFBundleExecutable:            executable_file_name,
        CFBundleDevelopmentRegion:     'English',
        CFBundleInfoDictionaryVersion: '6.0',
        NSPrincipalClass:              'NSApplication',
        LSUIElement:                   spec.agent,
        LSMinimumSystemVersion:        '10.6.7', # should match MacRuby
      }
      info[:CFBundleIconFile] = File.basename(spec.icon) if spec.icon_exists?

      File.open(info_plist_file, 'w') { |f| f.write info.to_plist }
    end

    # @todo something better than puts `gcc`
    def build_executable
      File.open(objective_c_source_file, 'wb') do |f|
        f.write %{
            #import <MacRuby/MacRuby.h>

            int main(int argc, char *argv[])
            {
                return macruby_main("rb_main.rb", argc, argv);
            }
        }
      end
      Dir.chdir(macos_root) do
        puts `gcc main.m -o #{executable_file_name} -arch x86_64 -framework MacRuby -framework Foundation -fobjc-gc-only`
      end
      File.unlink(objective_c_source_file)
    end

    # Borrow rb_main from MacRuby Xcode templates
    def write_ruby_main
      File.open(main_ruby_source_file, 'wb') do |f|
        f.write <<-EOF
    # Borrowed from the MacRuby sources on April 18, 2011
    framework 'Cocoa'

    # Loading all the Ruby project files.
    main = File.basename(__FILE__, File.extname(__FILE__))
    dir_path = NSBundle.mainBundle.resourcePath.fileSystemRepresentation
    dir_path += "/lib/"
    Dir.glob(File.join(dir_path, '*.{rb,rbo}')).map { |x| File.basename(x, File.extname(x)) }.uniq.each do |path|
    if path != main
      require File.join(dir_path, path)
    end
    end

    # Starting the Cocoa main loop.
    NSApplicationMain(0, nil)
        EOF
      end
    end

    def bundle_root
      "#{spec.name}.app"
    end

    def contents_root
      File.join(bundle_root, 'Contents')
    end

    def frameworks_root
      File.join(contents_root, 'Frameworks')
    end

    def macos_root
      File.join(contents_root, 'MacOS')
    end

    def resources_root
      File.join(contents_root, 'Resources')
    end

    def info_plist_file
      File.join(contents_root, 'Info.plist')
    end

    def icon_file
      File.join(resources_root, "#{spec.name}.icns")
    end

    def pkg_info_file
      File.join(contents_root, 'PkgInfo')
    end

    def executable_file_name
      spec.name.gsub(/\s+/, '')
    end

    def executable_file
      File.join(macos_root, executable_file_name)
    end

    def objective_c_source_file
      File.join(macos_root, 'main.m')
    end

    def main_ruby_source_file
      File.join(resources_root, 'rb_main.rb')
    end
  end
end
