
module Stratos

  RUBY = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name']).sub(/.*\s.*/m, '"\&"')

  class Command < Vagrant.plugin("2", "command")
    def execute

      opts = OptionParser.new do |o|
        o.banner = "Usage: vagrant script scriptname.rb"
      end
      argv = parse_options(opts)

      # TODO check if scriptname not provided and usage usage 
      puts argv

      vagrant_output = `vagrant help`.split( /\n/ )

      puts vagrant_output[0]

      return 0
    end
  end
end
