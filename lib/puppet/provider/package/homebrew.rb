require 'puppet/provider/package'

Puppet::Type.type(:package).provide(:brew, :parent => Puppet::Provider::Package) do
  CUSTOM_ENVIRONMENT = { "HOMEBREW_CACHE" => "/Library/Caches/Homebrew", "HOMEBREW_LOGS" => "/Library/Logs/Homebrew/" }
  desc "Package management using HomeBrew on OS X"

  confine  :operatingsystem => :darwin

  has_feature :installable, :install_options
  has_feature :versionable
  has_feature :upgradeable
  has_feature :uninstallable

  commands :id   => "/usr/bin/id"
  commands :stat => "/usr/bin/stat"
  commands :sudo => "/usr/bin/sudo"
  commands :brew => "/usr/local/bin/brew"

  def self.execute(cmd)
    owner = super([command(:stat), '-nf', '%Uu', command(:brew)]).to_i
    Puppet.debug "command owner is: #{owner}"
    if super([command(:id), '-u']).to_i.zero?
      Puppet.debug "running command in sudo environment as current user is root"
      super(cmd, :uid => owner, :failonfail => true, :combine => true, :custom_environment => CUSTOM_ENVIRONMENT)
    else
      Puppet.debug "running command with current (non-root) user"
      super(cmd, :failonfail => true, :combine => true, :custom_environment => CUSTOM_ENVIRONMENT)
    end
  end

  def execute(*args)
    self.class.execute(*args)
  end

  def linkapps?
    @resource[:linkapps] && @resource[:linkapps] == :true
  end

  def install_options
    Array(resource[:install_options]).flatten.compact
  end

  # Install packages, known as formulas, using brew.
  def install
    should = @resource[:ensure]

    Puppet.notice "Installing #{@resource[:name]}"
    package_name = @resource[:name]
    case should
    when true, false, Symbol
      # pass
    else
      package_name += "-#{should}"
    end
    Puppet.debug "  Package: #{package_name}"

    if install_options.any?
      output = execute([command(:brew), :install, package_name, *install_options])
    else
      output = execute([command(:brew), :install, package_name])
    end

    # Fail hard if there is no formula available.
    if output =~ /Error: No available formula/
      raise Puppet::ExecutionFailure, "Could not find package #{@resource[:name]}"
    end

    if linkapps?
      output = execute([command(:brew), 'linkapps'])
    end
  end

  def uninstall
    Puppet.notice "Uninstalling #{@resource[:name]}"
    execute([command(:brew), :uninstall, @resource[:name]])
  end

  alias :update :install

  def query
    Puppet.debug "Querying #{@resource[:name]}"
    begin
      cellar_path = execute([command(:brew), '--cellar']).chomp
      Puppet.debug "Cellars path: #{cellar_path}"
      info = execute([command(:brew), :info, @resource[:name]]).split("\n").grep(/^#{cellar_path}/).first
      return nil if info.nil?
      version = info[%r{^#{cellar_path}/[^/]+/(\S+)}, 1]
      Puppet.debug "  Package #{@resource[:name]} is at version: #{version}.\n  info: #{info}"
      {
        :name     => @resource[:name],
        :ensure   => version,
        :provider => :brew
      }
    rescue Puppet::ExecutionFailure
      raise Puppet::Error, "Brew error: #{$!}"
    end
  end

  def latest
    info = execute([command(:brew), :info, @resource[:name]])
    return nil if $CHILD_STATUS != 0 or info =~ /^Error/
    return 'HEAD' if info =~ /\bHEAD\b/
    return info.lines[0].split[0]
  end

  def self.package_list(options={})
    Puppet.debug "Listing brews"
    brew_list_command = [command(:brew), "list", "--versions"]

    if name = options[:justme]
      brew_list_command << name
    end

    begin
      list = execute(brew_list_command).
        lines.
        map {|line| name_version_split(line) }
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not list packages: #{detail}"
    end

    if options[:justme]
      return list.shift
    else
      return list
    end
  end

  def self.name_version_split(line)
    if line =~ (/^(\S+)\s+(.+)/)
      name = $1
      version = $2
      Puppet.debug "  Package #{name} is at version: #{version}."
      {
        :name     => name,
        :ensure   => version,
        :provider => :brew
      }
    else
      Puppet.warning "Could not match #{line}"
      nil
    end
  end

  def self.instances
    Puppet.debug "Listing currently install brews"
    package_list.collect { |hash| new(hash) }
  end
end