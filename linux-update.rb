#!/usr/bin/env ruby

require 'shellwords'
require 'getoptlong'
require 'json'
require 'pathname'
require 'shell'
require 'uri'

def load_required_gem lib, gem = nil, name = nil
	gem ||= lib
	name ||= gem
	require lib
rescue LoadError
	STDERR.puts <<EOF
Loading #{name} failed. Please install it first:
	sudo gem install #{gem}
EOF
	raise
end

load_required_gem 'thor', nil, 'Thor'
load_required_gem 'irb-pager', nil, 'IRB::Pager'
load_required_gem 'httpclient', nil, 'HTTPClient'
load_required_gem 'versionomy', nil, 'Versionomy'

module LinuxUpdate
	Release = Struct.new :version, :moniker, :source, :pgp, :released, :gitweb, :changelog, :patch_full, :patch_incremental, :iseol
	class Release
		include Comparable
		def self.parse json
			return nil  if json['version'] =~ /^next-/
			data = members.map {|m| json[m.to_s] }
			data[0] = Versionomy.parse data[0]
			data[2] = URI.parse data[2]
			data[3] = URI.parse data[3]
			data[4] = Time.at data[4]['timestamp'].to_i
			new *data
		end

		def stable?() 'stable' == moniker end
		def mainline?() 'mainline' == moniker end
		def longterm?() 'longterm' == moniker end
		def linux_next?() 'linux-next' == moniker end
		alias eol? iseol
		alias end_of_life? iseol

		def <=>( other) version <=> other.version end

		def to_s
			r = "linux-#{version} (#{moniker})"
			r += " (EOL)"  if end_of_life?
			r
		end
	end

	class Fetched
		attr_reader :dir
		def initialize dir
			@dir = Pathname.new dir
		end

		def make *opts, &block
			block ||= lambda {|rd| IO::copy_stream rd, STDOUT }
			dir = @dir.to_s
			rd, wr = IO.pipe
			pid = fork do
				STDOUT.reopen wr
				rd.close
				exec 'make', '-C', dir, *opts
			end
			wr.close
			wr = nil
			reader = Thread.new { block.call rd }
			Process.waitpid pid
			raise Base::MakeFailed, "make #{opts.join ' '}" unless 0 == $?.exitstatus
			reader.value
		ensure
			rd.close  if rd
			wr.close  if wr	
		end

		def version
			@version ||= make '-is', 'kernelversion' do |rd|
				Versionomy.parse rd.readlines.join.chomp
			end
		end

		def config
			dir + '.config'
		end

		def configured?
			return @configured  if @configured
			@configured = config.exist?
		end

		def <=>( other) version <=> other.version end

		def to_s
			r = "#{dir}"
			r += " #{version}"  if @version
			r += " #{configured? ? :configured : 'not configured'}"  if nil != @configured
			r
		end

		def open_config opts = nil, &block
			opts ||= 'r'
			if block_given?
				File.open config, opts, &block
			else
				File.open config, opts
			end
		end

		def import_config_from_io( io) open_config('w') {|c| io.each_line {|l| c.print l } } end

		def import_config file_or_io_or_fetched
			case file_or_io_or_fetched
			when IO then import_config_from_io file_or_io_or_fetched
			when Fetched
				file_or_io_or_fetched.open_config &method(:import_config_from_io)
			else
				File.open file_or_io_or_fetched.to_s, &method(:import_config_from_io)
			end
		end

		def oldconfig
			make 'oldconfig'
		end

		def menuconfig
			make 'menuconfig'
		end

		def compile
			make 'all'
		end

		def install
			make 'modules_install', 'install'
		end
	end

	class Base
		class Error <Exception
		end
		class InvalidVersionType <Error
		end
		class MakeFailed <Error
		end
		attr_reader :releases_uri, :sources_base_dir
		ReleasesURI = 'https://www.kernel.org/releases.json'
		SourcesBaseDir = '/usr/src'

		def releases_uri= uri
			@releases_uri = URI.parse uri.to_s
		end

		def sources_base_dir= dir
			@sources_base_dir = Pathname.new dir.to_s
		end

		def initialize
			self.releases_uri = ENV['LINUX_RELEASE_URI'] || ReleasesURI
			self.sources_base_dir = ENV['LINUX_SOURCES_BASE_DIR'] || SourcesBaseDir
		end

		def releases
			return @releases  if @releases
			json = JSON.parse HTTPClient.get_content( @releases_uri)
			@releases = json['releases'].map {|r| Release.parse r }.compact
		end

		def releases_moniker moniker = nil
			moniker ? releases.select {|r| moniker == r.moniker } : releases
		end

		def fetched
			@fetched ||= Dir[ @sources_base_dir + 'linux-*'].map {|d| Fetched.new d }
		end

		def configured()  fetched.select &:configured?  end
		def unconfigured()  fetched.reject &:configured?  end

		def find_fetched_version version
			case version
			when Fetched then version
			when Versionomy then fetched.find {|f| version == f.version }
			when Release then __callee__ version.version
			when String then __callee__ Versionomy.parse( version)
			when nil, false then fetched.max
			else raise InvalidVersionType, "I know Fetched, Versionomy, Release and String, but what is #{version.class}?"
			end
		end

		def exist? file
			Pathname.new( file.to_s).exist?
		end

		def download release_or_uri
			uri = case release_or_uri
				when Release then release_or_uri.source.to_s
				when URI, String then release_or_uri.to_s
				else raise UnexpectedThingToDownload, "This is no URI, String or Release"
				end
			dir = @sources_base_dir
			::Shell.new.transact do
				self.verbose = 0
				chdir dir
				system( 'curl', uri) | system( 'tar', '-xJf', '-')
			end
		end

		def oldconfig_prepare version = nil, config = nil
			version = find_fetched_version version
			config = case config
				when lambda {|x| Pathname.new( config.to_s).exist? } then config
				when nil, false then configured.max.config
				else find_fetched_version( config).config
				end
			[version, config]
		end
	end

	class Cmd < Thor
		class Error < Exception
		end
		class NoAvailableRelease < Error
		end
		class InvalidVersionType < Error
		end

		option :latest, type: :boolean, aliases: '-l', desc: 'Only the most actual linux kernel.'
		option :moniker, type: :string, aliases: '-m', desc: 'stable, mainline, longterm (default: no moniker)'
		desc 'releases [MONIKER]', 'Prints known linux-kernel releases'
		def releases moniker = nil
			listing base.releases_moniker( moniker || options[:moniker])
		end

		option :latest, type: :boolean, aliases: '-l', desc: 'Only the most actual linux kernel.'
		desc 'fetched', 'Prints all fetched linux-kernel'
		def fetched
			listing base.fetched
		end

		option :print, type: :boolean, aliases: '-p', desc: 'Only print the URI. No fetch.'
		option :any, type: :boolean, aliases: '-a', desc: 'Select any versions.'
		option :longterm, type: :boolean, aliases: '-o', desc: 'Select long term versions.'
		option :stable, type: :boolean, aliases: '-s', desc: 'Select stable versions (default).'
		option :mainline, type: :boolean, aliases: '-m', desc: 'Select mainline versions.'
		desc 'fetch [VERSION]', 'Download linux-kernel'
		def fetch version = nil
			rs = nil
			if version
				version = Versionomy.parse version
				rs = base.releases.select! {|r| version == r.version }
			else
				moniker = :stable
				moniker = :mainline  if options[:mainline]
				moniker = nil  if options[:any]
				rs = base.releases_moniker moniker.to_s
			end
			release = rs.max
			raise NoAvailableRelease, "There is no available release which matchs your wishes."  unless release
			if options[:print]
				puts release.source
				return
			end
			base.download release
		end

		desc 'importconfig [VERSION] [CONFIG]', 'Imports an other config from file or an other source directory. (default: most actual version with config to most actual version).'
		def importconfig version, config = nil
			version, config = base.oldconfig_prepare( version, options[:config])
			version.import_config config  if config
		end

		option :config, type: :string, aliases: '-c', default: false,
			desc: 'Which pre existing config should be used? Can be an other linux-VERSION with an old config or a config-file. --no-config will prevent copying a config.'
		desc 'oldconfig [VERSION]', 'Configure linux-VERSION (default: most actual version).'
		long_desc <<-ELD
		First it will copy an older config to your sources-directory, if needed and not --no-config.
		If you use `--config CONFIG`, the existing config will be replaced by CONFIG!
		Second make oldconfig will called.
		ELD
		def oldconfig version = nil
			version, config = base.oldconfig_prepare( version, options[:config])
			version.import_config config  if nil != options['config'] and config and not version.config.exist?
			version.oldconfig
		end

		option :config, type: :string, aliases: '-c', default: false,
			desc: 'Which pre existing config should be used? Can be an other linux-VERSION with an old config or a config-file. --no-config will prevent copying a config.'
		desc 'oldconfig [VERSION]', 'Configure linux-VERSION (default: most actual version).'
		long_desc <<-ELD
		First it will copy an older config to your sources-directory, if needed and not --no-config.
		If you use `--config CONFIG`, the existing config will be replaced by CONFIG!
		Second make oldconfig will called.
		ELD
		desc 'menuconfig|configure [VERSION]', 'Configure your linux-VERSION. (default: most actual version).'
		def menuconfig version = nil
			version, config = base.oldconfig_prepare( version, options[:config])
			version.import_config config  if nil != options['config'] and config and not version.config.exist?
			version.menuconfig
		end
		map configure: :menuconfig

		desc 'compile [VERSION]', 'Will compile kernel and modules.'
		def compile version = nil
			version = base.find_fetched_version version
			version.compile
		end

		desc 'install [VERSION]', 'Will install kernel and modules. It will trigger updating third-party-modules.'
		def install version = nil
			version = base.find_fetched_version version
			version.install
		end

		desc 'all [VERSION]', 'Will oldconfig, compile and install kernel and modules. See these methods.'
		def all version = nil
			version, config = base.oldconfig_prepare( version, options[:config])
			version.import_config config  if nil != options['config'] and config and not version.config.exist?
			version.oldconfig
			version.compile
			version.install
		end

		no_commands do
			def base
				@base ||= Base.new
			end

			def listing list
				list.each do |e|
					e.configured?  if e.is_a? Fetched
				end
				if options[:latest]
					puts list.max
				else
					puts list.sort {|a,b|b<=>a}
				end
			end
		end
	end
end

begin # if __FILE__ == $0
	$debug = true  if $DEBUG
	LinuxUpdate::Cmd.start ARGV
rescue LinuxUpdate::Cmd::Error, LinuxUpdate::Base::Error
	STDERR.puts "Error: #{$!}"
	STDERR.puts $!.backtrace.map {|c| "\t#{c}" }  if $debug
	raise
	#exit 1
rescue Object
	STDERR.puts "Unknown and unexpected Error: #{$!} (#{$!.class})"
	STDERR.puts $!.backtrace.map {|c| "\t#{c}" }  if $debug
	raise
	#exit 2
end  if __FILE__ == $0
