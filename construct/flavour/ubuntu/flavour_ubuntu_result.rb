
module Construct
module Flavour
module Ubuntu

  class EtcNetworkIptables
    def initialize
      @mangle = Section.new('mangle')
      @nat = Section.new('nat')
      @raw = Section.new('raw')
      @filter = Section.new('filter')
    end
    def self.prefix(unused, unused2)
      "# generated by construct"
    end
    class Section
      class Block
        def initialize(section)
          @section = section
          @rows = []
        end
        class Row
          include Util::Chainable
          chainable_attr_value :row, nil
          chainable_attr_value :table, nil
          chainable_attr_value :chain, nil
        end
        class RowFactory
          include Util::Chainable
          chainable_attr_value :table, nil
          chainable_attr_value :chain, nil
          chainable_attr_value :rows, nil
          def create
            ret = Row.new.table(get_table).chain(get_chain)
            get_rows.push(ret)
            ret
          end
        end
        def table(table, chain = nil)
          RowFactory.new.rows(@rows).table(table).chain(chain)
        end
        def prerouting
          table("", 'PREROUTING')
        end
        def postrouting
          table("", 'POSTROUTING')
        end
        def forward
          table("", 'FORWARD')
        end
        def output
          table("", 'OUTPUT')
        end
        def input
          table("", 'INPUT')
        end
        def commit
          #puts @rows.inspect
          tables = @rows.inject({}) do |r, row|
            r[row.get_table] ||= {}
            r[row.get_table][row.get_chain] ||= []
            r[row.get_table][row.get_chain] << row
            r
          end
          return "" if tables.empty?
          ret = ["*#{@section.name}"]
          ret += tables.keys.sort.map do |k| 
            v = tables[k]
            if k.empty? 
              v.keys.map{|o| ":#{o} ACCEPT [0:0]" }
            else
              ":#{k} - [0:0]"
            end
          end
          tables.each do |k,v|
            v.each do |chain, rows|
              table = !k.empty? ? "-A #{k}" : "-A #{chain}"
              rows.each do |row|
                ret << "#{table} #{row.get_row}"
              end
            end
          end
          ret << "COMMIT"
          ret << ""
          ret.join("\n")
        end
      end

      def initialize(name)
        @name = name
        @ipv4 = Block.new(self)
        @ipv6 = Block.new(self)
      end
      def name
        @name
      end
      def ipv4
        @ipv4
      end
      def ipv6
        @ipv6
      end
      def commitv6
        @ipv6.commit
      end
      def commitv4
        @ipv4.commit
      end
    end
    def mangle
      @mangle
    end
    def raw
      @raw
    end
    def nat
      @nat
    end
    def filter
      @filter
    end
    def commitv4
      mangle.commitv4+raw.commitv4+nat.commitv4+filter.commitv4
    end
    def commitv6
      mangle.commitv6+raw.commitv6+nat.commitv6+filter.commitv6
    end
  end

  class EtcNetworkInterfaces
    def initialize(result)
      @result = result
      @entries = {}
    end
    def self.prefix(unused, unused2)
    end
    class Entry
      class Header
        MODE_MANUAL = :manual
        MODE_DHCP = :dhcp
        MODE_LOOPBACK = :loopback
        PROTO_INET6 = :inet6
        PROTO_INET4 = :inet
        AUTO = :auto
        def mode(mode)
          @mode = mode
          self
        end
        def protocol(protocol)
          @protocol = protocol
          self
        end
        def noauto
          @auto = false
          self
        end
        def initialize(entry)
          @entry = entry
          @auto = true
          @mode = MODE_MANUAL
          @protocol = PROTO_INET4
          @interface_name = nil
        end
        def interface_name(name)
          @interface_name = name
        end
        def get_interface_name
          @interface_name || @entry.iface.name
        end
        def commit
          return "" if @entry.skip_interfaces?
          out = <<OUT
# #{@entry.iface.clazz.name}
#{@auto ? "auto #{get_interface_name}" : ""}
iface #{get_interface_name} #{@protocol.to_s} #{@mode.to_s}
  up   /bin/bash /etc/network/#{get_interface_name}-up.iface
  down /bin/bash /etc/network/#{get_interface_name}-down.iface
OUT
        end
      end
      class Lines
        def initialize(entry)
          @entry = entry
          @lines = []
          @ups = []
          @downs = []
        end
        def up(block)
          @ups += block.each_line.map{|i| i.strip }.select{|i| !i.empty? }
        end
        def down(block)
          @downs += block.each_line.map{|i| i.strip }.select{|i| !i.empty? }
        end
        def add(block)
          @lines += block.each_line.map{|i| i.strip }.select{|i| !i.empty? }
        end
        def self.prefix(unused, unused2)
          "#!/bin/bash"
        end
        def write_s(direction, blocks)
          @entry.result.add(self.class, <<BLOCK, Construct::Resource::Rights::ROOT_0755, "etc", "network", "#{@entry.header.get_interface_name}-#{direction}.iface")
exec > >(logger -t "#{@entry.header.get_interface_name}-#{direction}) 2>&1
#{blocks.join("\n")}
iptables-restore < /etc/network/iptables.cfg
ip6tables-restore < /etc/network/ip6tables.cfg
BLOCK
        end
        def commit
          write_s("up", @ups) 
          write_s("down", @downs) 
          sections = @lines.inject({}) {|r, line| key = line.split(/\s+/).first; r[key] ||= []; r[key] << line; r }
          sections.keys.sort.map do |key| 
            if sections[key]
              sections[key].map{|j| "  #{j}" }
            else
              nil
            end
          end.compact.flatten.join("\n")+"\n\n"
        end
      end
      def iface
        @iface
      end
      def initialize(result, iface)
        @result = result
        @iface = iface
        @header = Header.new(self)
        @lines = Lines.new(self)
        @skip_interfaces = false
      end
      def result
        @result
      end
      def name
        @iface.name
      end
      def header
        @header
      end
      def lines
        @lines
      end
      def skip_interfaces?
        @skip_interfaces
      end
      def skip_interfaces
        @skip_interfaces = true
        self
      end
      def commit
        @header.commit + @lines.commit
      end
    end
    def get(iface) 
      throw "clazz needed #{iface.name}" unless iface.clazz
      @entries[iface.name] ||= Entry.new(@result, iface)
    end
    def commit
      #binding.pry
      out = [@entries['lo']]
      clazzes = {}
      @entries.values.each do |entry|
        name = entry.iface.clazz.name[entry.iface.clazz.name.rindex(':')+1..-1]
        #puts "NAME=>#{name}:#{entry.iface.clazz.name.rindex(':')+1}:#{entry.iface.clazz.name}:#{entry.name}"
        clazzes[name] ||= []
        clazzes[name] << entry
      end
      ['Device', 'Bond', 'Vlan', 'Bridge', 'Gre'].each do |type|
        out += (clazzes[type]||[]).select{|i| !out.first || i.name != out.first.name }.sort{|a,b| a.name<=>b.name }
      end
      out.flatten.compact.inject("") { |r, entry| r += entry.commit; r }
    end
  end

  class Result
    def initialize(host)
      @host = host
      @etc_network_interfaces = EtcNetworkInterfaces.new(self)
      @etc_network_iptables = EtcNetworkIptables.new
      @result = {}
    end
    def etc_network_interfaces
      @etc_network_interfaces
    end
    def etc_network_iptables
      @etc_network_iptables
    end
    def host
      @host
    end
    def empty?(name)
      not @result[name]
    end
    class ArrayWithRight < Array
      attr_accessor :right
      def initialize(right)
        self.right = right
      end
    end
    def add(clazz, block, right, *path)
      path = File.join(*path)
      throw "not a right #{path}" unless right.respond_to?('right') && right.respond_to?('owner')
      unless @result[path]
        @result[path] = ArrayWithRight.new(right)
        @result[path] << [clazz.prefix(@host, path)].compact
      end
      @result[path] << block+"\n"
    end
    def replace(clazz, block, right, *path) 
      path = File.join(*path)
      replaced = !!@result[path]
      @result.delete(path) if @result[path] 
      add(clazz, block, right, *path)
      replaced
    end
    def directory_mode(mode)
      mode = mode.to_i(8)
      0!=(mode & 06) && (mode = (mode | 01))
      0!=(mode & 060) && (mode = (mode | 010)) 
      0!=(mode & 0600) && (mode = (mode | 0100))
      "0#{mode.to_s(8)}"
    end
    def import_fname(fname)
      '/'+File.dirname(fname)+"/.#{File.basename(fname)}.import"
    end

    def commit
      add(EtcNetworkIptables, etc_network_iptables.commitv4, Construct::Resource::Rights::ROOT_0644, "etc", "network", "iptables.cfg")
      add(EtcNetworkIptables, etc_network_iptables.commitv6, Construct::Resource::Rights::ROOT_0644, "etc", "network", "ip6tables.cfg")
      add(EtcNetworkInterfaces, etc_network_interfaces.commit, Construct::Resource::Rights::ROOT_0644, "etc", "network", "interfaces")
    out = [<<BASH]
#!/bin/bash
hostname=`hostname`
if [ $hostname != "" ]
then
  hostname=`grep '^\s*[^#]' /etc/hostname`
fi
if [ $hostname != #{@host.name} ]
then
 echo 'You try to run a deploy script on a host which has not the right name $hostname != #{@host.name}'
else
 echo Configure Host #{@host.name}
fi
updates=''
for i in language-pack-en language-pack-de git aptitude traceroute vlan bridge-utils tcpdump mtr-tiny \\
bird keepalived strace iptables conntrack openssl racoon ulogd2
do
 dpkg -l $i > /dev/null 2> /dev/null 
 if [ $? != 0 ]
 then
    updates="$updates $i"
 fi
done
apt-get -qq -y install $updates
if [ ! -d /root/construct.git ]
then
 echo generate history in /root/construct.git
 git init --bare /root/construct.git
fi
BASH
    out += @result.map do |fname, block|
      text = block.flatten.select{|i| !(i.nil? || i.strip.empty?) }.join("\n")
      next if text.strip.empty?
      Util.write_str(text, @host.name, fname)
#          binding.pry
      #
      [
        File.dirname("/#{fname}").split('/')[1..-1].inject(['']) do |res, part| 
          res << File.join(res.last, part); res 
        end.select{|i| !i.empty? }.map do |i| 
          "[ ! -d #{i} ] && mkdir #{i} && chown #{block.right.owner} #{i} && chmod #{directory_mode(block.right.right)} #{i}"
        end,
        "openssl enc -base64 -d > #{import_fname(fname)} <<BASE64", Base64.encode64(text), "BASE64",
        <<BASH]
chown #{block.right.owner} #{import_fname(fname)}
chmod #{block.right.right} #{import_fname(fname)}
if [ ! -f /#{fname} ]
then
    mv #{import_fname(fname)} /#{fname}
    echo created /#{fname} to #{block.right.owner}:#{block.right.right}
else
  diff -rq #{import_fname(fname)} /#{fname}
  if [ $? != 0 ]
  then
    mv #{import_fname(fname)} /#{fname}
    echo updated /#{fname} to #{block.right.owner}:#{block.right.right}
  else
    rm #{import_fname(fname)}
  fi
  git --git-dir /root/construct.git --work-tree=/ add /#{fname}
fi
BASH
    end.flatten
    out += [<<BASH] 
git --git-dir /root/construct.git config user.name #{ENV['USER']}
git --git-dir /root/construct.git config user.email #{ENV['USER']}@construct.net
git --git-dir /root/construct.git --work-tree=/ commit -q -m '#{ENV['USER']} #{`hostname`.strip} #{`git log --pretty=format:"%h - %an, %ar : %s" -1`.strip}' > /dev/null && echo COMMITED
BASH
    Util.write_str(out.join("\n"), @host.name, "deployer.sh")
  end
  end

end
end
end