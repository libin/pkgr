require 'pkgr/builder'
require 'pkgr/git'

module Pkgr
  class Dispatcher
    attr_reader :path, :host, :config

    def initialize(path, opts = {})
      opts = opts.dup
      @path = path
      @host = opts.delete(:host)
      @config = Config.new(opts)
    end

    def setup
      tarify if File.directory?(path)
      config.before_precompile = File.expand_path(config.before_precompile) if config.before_precompile
      config.compile_cache_dir = File.expand_path(config.compile_cache_dir) if config.compile_cache_dir
    end

    def call
      setup

      if remote?
        command = %{ ( cat "#{path}" | ssh "#{host}" pkgr package - #{config.to_args.join(" ")} ) && rsync "#{host}":~/*.deb .}
        Pkgr.debug command
        IO.popen(command) do |io|
          until io.eof?
            data = io.gets
            print data
          end
        end
        raise "Error when running remote packaging command. Please make sure to run `sudo apt-get install -y ruby1.9.1-full build-essential git-core && sudo gem install pkgr --version #{Pkgr::VERSION}`" unless $?.exitstatus.zero?
      else
        Builder.new(path, config).call
      end
    end

    def tarify
      tmpfile = Tempfile.new(["pkgr-tarball", ".tar.gz"])
      system("tar czf #{tmpfile.path} --exclude .git --exclude .svn -C \"#{path}\" .") || raise(Pkgr::Errors::Base, "Can't compress input directory")
      # Remove any non-digit characters that may be before the version number
      config.version ||= (Git.new(path).latest_tag || "").gsub(/^[^\d](\d.*)/, '\1')
      config.compile_cache_dir ||= File.join(path, ".git", "cache")
      config.name ||= File.basename(path)
      @path = tmpfile.path
    end

    def remote?
      !host.nil?
    end
  end
end