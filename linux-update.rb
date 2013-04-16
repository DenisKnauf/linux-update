#!/usr/bin/env ruby

require 'shellwords'
require 'getoptlong'
require 'json'
require 'pathname'
require 'shell'
require 'uri'

class RequiredGems
	attr_reader :requires, :failed
	def self.require &block
		rg = new
		block.call rg, &rg.method(:push)
		rg.require
	end

	def initialize
		@requires, @failed = [], []
	end

	def push lib, gem = nil, name = nil
		gem ||= lib
		name ||= gem
		@requires.push [lib, gem, name]
	end

	def try_require lib
		require lib
		true
	rescue LoadError
		false
	end

	def require lib = nil
		return super lib  if lib # if lib given, require it.

		@failed = @requires.reject {|(lib, _, _)| try_require lib }
		return  if @failed.empty?
		STDERR.puts <<EOF
Loading of #{@failed.map{|(_,_,n)|n}.join ', '} failed.
Please install if first:
	sudo gem install #{@failed.map{|(_,g,_)|g}.join ' '}
EOF
		exit 127
	end
end

def requires_lib_gem &block
	requires = []
	push = lambda {|lib, gem = lib, name = gem| requires.push [lib, gem, name] }
	block.call &push
	failed = requires.reject do |(lib, _, _)|
		begin
			require lib
			true
		rescue LoadError
			false
		end
	end
	return  if failed.empty?
	STDERR.puts <<EOF
Loading of #{failed.map{|(_,_,n)|n}.join ', '} failed.
Please install if first:
sudo gem install #{failed.map{|(_,g,_)|g}.join ' '}
EOF
	exit 127
end

requires_lib_gem do |&push|
	push[ 'thor', nil, 'Thor']
	push[ 'irb-pager', nil, 'IRB::Pager']
	push[ 'active_support/all', 'activesupport', 'ActiveSupport']
	push[ 'excon', nil, 'Excon']
	push[ 'versionomy', nil, 'Versionomy']
end


module LinuxUpdate
	Release = Struct.new :version, :moniker, :source, :pgp, :released, :gitweb, :changelog, :patch_full, :patch_incremental, :iseol
	class Release
		include Comparable
		def self.parse json
			return nil  if json['version'] =~ /^next-/
				data = members.map {|m| json[m.to_s] }
			data[0] = Versionomy.parse data[0]
			data[2] = URI.parse data[2] rescue
			data[3] = URI.parse data[3] rescue
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
			info "Import config #{file_or_io_or_fetched}" 
			case file_or_io_or_fetched
			when IO then import_config_from_io file_or_io_or_fetched
			when Fetched
				file_or_io_or_fetched.open_config &method(:import_config_from_io)
			else
				File.open file_or_io_or_fetched.to_s, &method(:import_config_from_io)
			end
		end

		def oldconfig
			info 'make oldconfig'
			make 'oldconfig'
		end

		def menuconfig
			info 'make menuconfig'
			make 'menuconfig'
		end

		def compile
			info 'make all'
			make 'all'
		end

		def install
			info 'make modules_install install'
			make 'modules_install', 'install'
		end

		def info text
			STDERR.puts "[#{version}] #{text}"
		end
	end

	class Base
		class Error <Exception
		end
		class InvalidVersionType <Error
		end
		class MakeFailed <Error
		end
		class DownloadFailed <Error
			def initialize uri
				super "Download of #{uri} failed."
			end
		end
		class UnpackFailed <Error
			def initialize tarball
				super "Unpack of #{tarball} failed."
			end
		end
		attr_reader :releases_uri, :sources_base_dir, :cache_dir
		ReleasesURI = 'https://www.kernel.org/releases.json'
		SourcesBaseDir = '/usr/src'
		CacheDir = '/var/cache/linux-update'

		def releases_uri=( uri) @releases_uri = URI.parse uri.to_s end
		def sources_base_dir=( dir) @sources_base_dir = Pathname.new dir.to_s end
		def cache_dir=( dir) @cache_dir = Pathname.new dir.to_s end

		def initialize
			self.releases_uri = ENV['LINUX_RELEASE_URI'] || ReleasesURI
			self.sources_base_dir = ENV['LINUX_SOURCES_BASE_DIR'] || SourcesBaseDir
			self.cache_dir = ENV['CacheDir'] || CacheDir
		end

		def info text
			STDERR.puts text
		end

		def releases
			return @releases  if @releases
			res = Excon.get @releases_uri.to_s, expects: 200
			json = JSON.parse res.body
			@releases = json['releases'].map {|r| Release.parse r }.compact
		end

		def releases_moniker moniker = nil
			moniker ? releases.select {|r| moniker == r.moniker } : releases
		end

		def fetched
			@fetched ||= Dir[ @sources_base_dir + 'linux-*'].
				map( &Pathname.method( :new)).
				select( &:directory?).
				map {|d| Fetched.new d }
		end

		def configured()  fetched.select &:configured?  end
		def unconfigured()  fetched.reject &:configured?  end

		def find_fetched_version version
			case version
			when Fetched then version
			when Versionomy::Value then fetched.find {|f| version == f.version }
			when Release then find_fetched_version version.version
			when String then find_fetched_version Versionomy.parse( version)
			when nil, false then fetched.max
			else raise InvalidVersionType, "I know Fetched, Versionomy, Release and String, but what is #{version.class}?"
			end
		end

		def exist? file
			Pathname.new( file.to_s).exist?
		end

		def format_bytes bytes
			case bytes
			when 0...1.kilobyte then "%6dB" % bytes
			when 0...1.megabyte then "%4dKiB" % (bytes / 1.kilobyte)
			when 0...1.gigabyte then "%4dMiB" % (bytes / 1.megabyte)
			when 0...1.terabyte then "%4dGiB" % (bytes / 1.gigabyte)
			when 0...1.petabyte then "%4dTiB" % (bytes / 1.terabyte)
			else "%4dEiB" % (bytes / 1.petabyte)
			end
		end

		def _download uri, file
			dest = Pathname.new "#{file}.download"
			info "Download #{uri} => #{tarball}"
			if true
				raise DownloadFailed, uri  unless Kernel.system( 'wget', '-c', '-O', dest.to_s, uri.to_s)
			else
				done = dest.size
				p dest => done
				dest.open 'a+' do |fd|
					streamer = lambda do |chunk, remaining, total|
						fd.write chunk
						count = total - remaining
						STDERR.print "\rloading %s/%s % 3d%%\e[J" % [
							format_bytes(count), format_bytes(total), 100.0*count/total ]
					end
					res = Excon.get uri.to_s,
						response_block: streamer,
						expects: 200,
						headers: {'Range' => "#{done}-" }
				end
			end
			dest.rename file
		end

		def _unpack tarball, destdir
			info "Unpack #{tarball} => #{destdir}"
			unless Kernel.system 'tar', '-C', destdir.to_s, '-xf', tarball.to_s
				raise UnpackFailed, tarball
			end
		end

		def download release_or_uri
			uri =
				case release_or_uri
				when Release then release_or_uri.source
				when URI, String then URI.parse release_or_uri.to_s
				else raise UnexpectedThingToDownload, "This is no URI, String or Release"
				end
			# We do not understand anything else than operating systems with / as separator
			@cache_dir.mkdir 0755  unless @cache_dir.exist?
			tarball = @cache_dir + File.basename( uri.path)
			_download uri, tarball  unless tarball.exist?
			_unpack tarball, @sources_base_dir
		end

		def oldconfig_prepare version = nil, config = nil
			version = find_fetched_version version
			config =
				case config
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
		def importconfig version = nil, config = nil
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

		option :any, type: :boolean, aliases: '-a', desc: 'Select any versions.'
		option :longterm, type: :boolean, aliases: '-o', desc: 'Select long term versions.'
		option :stable, type: :boolean, aliases: '-s', desc: 'Select stable versions (default).'
		option :mainline, type: :boolean, aliases: '-m', desc: 'Select mainline versions.'
		desc 'update [VERSION]', 'Download, compile and install linux-kernel'
		def update version = nil
			fetch version
			all version
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
