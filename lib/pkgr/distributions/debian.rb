require 'pkgr/buildpack'
require 'pkgr/process'
require 'yaml'
require 'erb'

module Pkgr
  module Distributions
    class Debian

      attr_reader :version
      def initialize(version)
        @version = version
      end

      def templates(app_name)
        list = []

        # directories
        [
          "usr/local/bin",
          "opt/#{app_name}",
          "etc/#{app_name}/conf.d",
          "etc/default",
          "etc/init",
          "var/log/#{app_name}"
        ].each{|dir| list.push Templates::DirTemplate.new(dir) }

        # default
        list.push Templates::FileTemplate.new("etc/default/#{app_name}", File.new(File.join(data_dir, "default.erb")))
        # upstart master
        list.push Templates::FileTemplate.new("etc/init/#{app_name}.conf", data_file("upstart/master.conf.erb"))
        # executable
        list.push Templates::FileTemplate.new("usr/local/bin/#{app_name}", File.new(File.join(data_dir, "runner.erb")), mode: 0755)
        # logrotate
        list.push Templates::FileTemplate.new("etc/logrotate.d/#{app_name}", File.new(File.join(data_dir, "logrotate.erb")))

        # NOTE: conf.d files are no longer installed here, since we don't want to overwrite any pre-existing config.
        # They're now installed in the postinstall script.

        list
      end

      def initializers_for(app_name, procfile_entries)
        list = []
        procfile_entries.select(&:daemon?).each do |process|
          Pkgr.debug "Adding #{process.inspect} to initialization scripts"
          list.push [process, Templates::FileTemplate.new("#{app_name}-#{process.name}.conf", data_file("upstart/process_master.conf.erb"))]
          list.push [process, Templates::FileTemplate.new("#{app_name}-#{process.name}-PROCESS_NUM.conf", data_file("upstart/process.conf.erb"))]
        end
        list
      end

      def check(config)
        missing_packages = (build_dependencies(config.build_dependencies) || []).select do |package|
          test_command = "dpkg -s '#{package}' > /dev/null 2>&1"
          Pkgr.debug "Running #{test_command}"
          ! system(test_command)
        end

        unless missing_packages.empty?
          package_install_command = "sudo apt-get install -y #{missing_packages.map{|package| "\"#{package}\""}.join(" ")}"
          if config.auto
            Pkgr.debug "Running command: #{package_install_command}"
            package_install = Mixlib::ShellOut.new(package_install_command)
            package_install.run_command
            package_install.error!
          else
            Pkgr.warn("Missing build dependencies detected. Run the following to fix: #{package_install_command}")
          end
        end
      end

      def fpm_command(build_dir, config)
        %{
          fpm -t deb -s dir  --verbose --force \
          -C "#{build_dir}" \
          -n "#{config.name}" \
          --version "#{config.version}" \
          --iteration "#{config.iteration}" \
          --url "#{config.homepage}" \
          --provides "#{config.name}" \
          --deb-user "root" \
          --deb-group "root" \
          -a "#{config.architecture}" \
          --description "#{config.description}" \
          --template-scripts \
          --before-install #{preinstall_file(config)} \
          --after-install #{postinstall_file(config)} \
          #{dependencies(config.dependencies).map{|d| "-d '#{d}'"}.join(" ")} \
          .
        }
      end

      def buildpacks(custom_buildpack_uri = nil)
        if custom_buildpack_uri
          uuid = Digest::SHA1.hexdigest(custom_buildpack_uri)
          [Buildpack.new(custom_buildpack_uri, :custom)]
        else
          case version
          when "wheezy"
            %w{
              https://github.com/heroku/heroku-buildpack-ruby.git
              https://github.com/heroku/heroku-buildpack-nodejs.git
              https://github.com/heroku/heroku-buildpack-java.git
              https://github.com/heroku/heroku-buildpack-play.git
              https://github.com/heroku/heroku-buildpack-python.git
              https://github.com/heroku/heroku-buildpack-php.git
              https://github.com/heroku/heroku-buildpack-clojure.git
              https://github.com/kr/heroku-buildpack-go.git
              https://github.com/miyagawa/heroku-buildpack-perl.git
              https://github.com/heroku/heroku-buildpack-scala
              https://github.com/igrigorik/heroku-buildpack-dart.git
              https://github.com/rhy-jot/buildpack-nginx.git
              https://github.com/Kloadut/heroku-buildpack-static-apache.git
            }.map{|url| Buildpack.new(url)}
          end
        end
      end

      def preinstall_file(config)
        @preinstall_file ||= begin
          source = File.join(data_dir, "hooks", "preinstall.sh")
          file = Tempfile.new("preinstall")
          file.write ERB.new(File.read(source)).result(config.sesame)
          file.rewind
          file
        end

        @preinstall_file.path
      end

      def postinstall_file(config)
        @postinstall_file ||= begin
          source = File.join(data_dir, "hooks", "postinstall.sh")
          file = Tempfile.new("postinstall")
          file.write ERB.new(File.read(source)).result(config.sesame)
          file.rewind
          file
        end

        @postinstall_file.path
      end

      def dependencies(other_dependencies = nil)
        deps = YAML.load_file(File.join(data_dir, "dependencies.yml"))
        (deps["default"] || []) | (deps[version] || []) | (other_dependencies || [])
      end

      def build_dependencies(other_dependencies = nil)
        deps = YAML.load_file(File.join(data_dir, "build_dependencies.yml"))
        (deps["default"] || []) | (deps[version] || []) | (other_dependencies || [])
      end

      def data_file(name)
        File.new(File.join(data_dir, name))
      end

      def data_dir
        File.join(Pkgr.data_dir, "distributions", "debian")
      end
    end
  end
end