require 'bosh/core/shell'
require 'bosh/stemcell/builder_options'
require 'bosh/stemcell/stemcell'
require 'forwardable'

module Bosh::Stemcell
  class BuildEnvironment
    extend Forwardable

    BUILD_TIME_MARKER_FILE = File.join(File.expand_path('../../../../..', __FILE__), 'build_time.txt')
    STEMCELL_BUILDER_SOURCE_DIR = File.join(File.expand_path('../../../../..', __FILE__), 'stemcell_builder')
    STEMCELL_SPECS_DIR = File.expand_path('../../..', File.dirname(__FILE__))

    def initialize(env, definition, version, os_image_tarball_path)
      @environment = env
      @definition = definition
      @os_image_tarball_path = os_image_tarball_path
      @version = version
      @stemcell_builder_options = BuilderOptions.new(
        env: env,
        definition: definition,
        version: version,
        os_image_tarball: os_image_tarball_path,
      )
      @shell = Bosh::Core::Shell.new
    end

    attr_reader :version

    def prepare_build
      if ENV['resume_from'].nil?
        sanitize
        prepare_build_path
      end
      copy_stemcell_builder_to_build_path
      prepare_work_root
      prepare_stemcell_path
      persist_settings_for_bash
    end

    def os_image_rspec_command
      [
        "cd #{STEMCELL_SPECS_DIR};",
        "OS_IMAGE=#{os_image_tarball_path}",
        "bundle exec rspec -fd",
        "spec/os_image/#{operating_system_spec_name}_spec.rb",
      ].join(' ')
    end

    def stemcell_rspec_command
      cmd = [
        "cd #{STEMCELL_SPECS_DIR};",
        "STEMCELL_IMAGE=#{image_file_path}",
        "STEMCELL_WORKDIR=#{work_path}",
        "OS_NAME=#{operating_system.name}",
        "OS_VERSION=#{operating_system.version}",
        "CANDIDATE_BUILD_NUMBER=#{@version}",
        "bundle exec rspec -fd#{exclude_exclusions}",
        "spec/os_image/#{operating_system_spec_name}_spec.rb",
        "spec/stemcells/#{operating_system_spec_name}_spec.rb",
        'spec/stemcells/go_agent_spec.rb',
        "spec/stemcells/#{infrastructure.name}_spec.rb",
        'spec/stemcells/stig_spec.rb',
        'spec/stemcells/cis_spec.rb'
      ]
      cmd << "spec/stemcells/#{operating_system.variant}_spec.rb" if operating_system.variant?
      cmd.join(' ')
    end

    def build_path
      File.join(build_root, 'build')
    end

    def stemcell_files
      definition.disk_formats.map do |disk_format|
        stemcell_filename = Stemcell.new(@definition, 'bosh-stemcell', @version, disk_format)
        File.join(work_path, stemcell_filename.name)
      end
    end

    def chroot_dir
      File.join(work_path, 'chroot')
    end

    def settings_path
      File.join(build_path, 'etc', 'settings.bash')
    end

    def work_path
      File.join(work_root, 'work')
    end

    def stemcell_tarball_path
      work_path
    end

    def stemcell_disk_size
      stemcell_builder_options.image_create_disk_size
    end

    def command_env
      "env #{hash_as_bash_env(proxy_settings_from_environment.merge(build_time_settings))}"
    end

    private

    def_delegators(
      :@definition,
      :infrastructure,
      :operating_system,
      :agent,
    )

    attr_reader(
      :shell,
      :environment,
      :definition,
      :stemcell_builder_options,
      :os_image_tarball_path,
    )

    def sanitize
      FileUtils.rm(Dir.glob('*.tgz'))

      shell.run("sudo umount #{File.join(work_path, 'mnt/tmp/grub', settings['stemcell_image_name'])} 2> /dev/null",
                { ignore_failures: true })

      shell.run("sudo umount #{image_mount_point} 2> /dev/null", { ignore_failures: true })

      shell.run("sudo rm -rf #{base_directory}", { ignore_failures: true })
    end

    def build_time_settings
      if File.exist?(BUILD_TIME_MARKER_FILE)
        return { 'BUILD_TIME' => File.read(BUILD_TIME_MARKER_FILE).chomp }
      elsif environment['BUILD_TIME']
        return { 'BUILD_TIME' => environment['BUILD_TIME'] }
      end
      {}
    end

    def operating_system_spec_name
      "#{operating_system.name}_#{operating_system.version}"
    end

    def prepare_build_path
      FileUtils.rm_rf(build_path, verbose: true) if File.exist?(build_path)
      FileUtils.mkdir_p(build_path, verbose: true)
    end

    def prepare_stemcell_path
      FileUtils.mkdir_p(File.join(work_path, 'stemcell'))
    end

    def copy_stemcell_builder_to_build_path
      FileUtils.cp_r(Dir.glob("#{STEMCELL_BUILDER_SOURCE_DIR}/*"), build_path, preserve: true, verbose: true)
    end

    def prepare_work_root
      FileUtils.mkdir_p(work_root, verbose: true)
    end

    def persist_settings_for_bash
      File.open(settings_path, 'a') do |f|
        f.printf("\n# %s\n\n", '=' * 20)
        settings.each do |k, v|
          f.print "#{k}=#{v}\n"
        end
      end
    end

    def exclude_exclusions
      [
      case infrastructure.name
      when 'alicloud'
        ' --tag ~exclude_on_alicloud'
      when 'vsphere'
        ' --tag ~exclude_on_vsphere'
      when 'vcloud'
        ' --tag ~exclude_on_vcloud'
      when 'warden'
        ' --tag ~exclude_on_warden'
      when 'aws'
        ' --tag ~exclude_on_aws'
      when 'openstack'
        ' --tag ~exclude_on_openstack'
      when 'cloudstack'
        ' --tag ~exclude_on_cloudstack'
      when 'azure'
        ' --tag ~exclude_on_azure'
      when 'softlayer'
        ' --tag ~exclude_on_softlayer'
      when 'google'
        ' --tag ~exclude_on_google'
      else
        nil
      end,
      if operating_system.variant?
        " --tag ~exclude_on_#{operating_system.variant}"
      end,
      ].compact.join(' ').rstrip
    end

    def image_file_path
      File.join(work_path, settings['stemcell_image_name'])
    end

    def image_mount_point
      File.join(work_path, 'mnt')
    end

    def settings
      stemcell_builder_options.default
    end

    def base_directory
      File.join('/mnt', 'stemcells', infrastructure.name, infrastructure.hypervisor, operating_system.name)
    end

    def build_root
      File.join(base_directory, 'build')
    end

    def work_root
      File.join(base_directory, 'work')
    end

    def proxy_settings_from_environment
      keep = %w(HTTP_PROXY HTTPS_PROXY NO_PROXY)

      environment.select { |k| keep.include?(k.upcase) }
    end

    def hash_as_bash_env(env)
      env.map { |k, v| "#{k}='#{v}'" }.join(' ')
    end
  end
end
