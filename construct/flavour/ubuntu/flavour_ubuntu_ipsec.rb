require 'construct/util.rb'

module Construct
module Flavour
module Ubuntu
  class Ipsec < OpenStruct
    def initialize(cfg)
      super(cfg)
    end
    def prefix(path)
      if File.basename(path) == "racoon.conf"
        return <<HEADER
# do not edit generated filed #{path}
path pre_shared_key "/etc/racoon/psk.txt";
path certificate "/etc/racoon/certs";
log info;
listen {
  isakmp #{self.remote.first_ipv6.to_s} [500];
  strict_address;
}
HEADER
      end
      return "# do not edit generated filed #{path}"
    end
    
    def build_gre_config() 
      iname = Util.clean_if("gt", self.other.host.name)
      writer = self.host.result.delegate.etc_network_interfaces.get(iname)
      writer.lines.add(<<UP)
up ip -6 tunnel add #{iname} mode ip6gre local #{self.my.first_ipv6} remote #{self.other.my.first_ipv6} 
up ip -6 addr add #{self.my.first_ipv6.to_string} dev #{iname}
up ip -6 link set dev #{iname} up
UP
      writer.lines.add(<<DOWN)
down ip -6 tunnel del #{iname}
DOWN
    end

    def build_racoon_config() 
      #binding.pry
      ret = <<RACOON
# #{self.cfg.name}
remote #{self.other.remote.first_ipv6.to_s} {
exchange_mode main;
lifetime time 24 hour;

proposal_check strict;
dpd_delay 30;
ike_frag on;                    # use IKE fragmentation
proposal {
  encryption_algorithm aes256;
  hash_algorithm sha1;
  authentication_method pre_shared_key;
  dh_group modp1536;
}

}
sainfo address #{self.my.first_ipv6} any address #{self.other.my.first_ipv6} any {
pfs_group 5;
encryption_algorithm aes256;
authentication_algorithm hmac_sha1;
compression_algorithm deflate;
lifetime time 1 hour;
}
sainfo address #{self.other.my.first_ipv6} any address #{self.my.first_ipv6} any {
pfs_group 5;
encryption_algorithm aes256;
authentication_algorithm hmac_sha1;
compression_algorithm deflate;
lifetime time 1 hour;
}
RACOON
      self.host.result.add(self, ret, Ubuntu.root, "etc", "racoon", "racoon.conf")
    end

    def build_config(unused, unused2)
      #binding.pry
      build_gre_config()
      build_racoon_config()
      host.result.add(self, "# #{self.cfg.name}\n#{self.other.remote.first_ipv6.to_s} #{Util.password(self.cfg.password)}", Ubuntu.root_600, "etc", "racoon", "psk.txt")
      ret = <<IPSEC
# #{self.cfg.name}
spdadd #{self.other.my.first_ipv6}  #{self.my.first_ipv6}  any -P in  ipsec esp/tunnel/#{self.other.remote.first_ipv6.to_s}-#{self.remote.first_ipv6.to_s}/unique;
spdadd #{self.my.first_ipv6}  #{self.other.my.first_ipv6}  any -P out ipsec esp/tunnel/#{self.remote.first_ipv6.to_s}-#{self.other.remote.first_ipv6.to_s}/unique;
IPSEC
      host.result.add(self, ret, Ubuntu.root, "etc", "ipsec-tools.d", "ipsec.conf")
    end
  end
end
end
end
