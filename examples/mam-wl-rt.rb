require 'resolv'

def mam_ipsec_connection(region, left, right, fw_suffix, vlan, fws = [])
    Construqt::Ipsecs.connection("#{left.name}<=>#{right.name}",
            "password" => IPSEC_PASSWORD,
            "transport_family" => Construqt::Addresses::IPV4,
            "mtu_v4" => 1360,
            "mtu_v6" => 1360,
            "keyexchange" => "ikev2",
            "left" => {
              "my" => region.network.addresses.add_ip("169.254.#{vlan}.1/30#SERVICE-IPSEC-#{fw_suffix}")
                        .add_ip("169.254.#{vlan}.5/30#SERVICE-TRANSIT-#{fw_suffix}#FANOUT-#{fw_suffix}-GW")
                        .add_ip("2602:ffea:1:7dd:#{vlan}::5/126#SERVICE-TRANSIT-#{fw_suffix}#FANOUT-#{fw_suffix}")
                        .add_route_from_tags("#NET-#{left.name}", "#GW-#{left.name}"),
              "host" => right,
              "remote" => region.interfaces.find(right, "eth0").address,
              "auto" => "add",
              "sourceip" => true
            },
            "right" => {
              "my" => region.network.addresses.add_ip("169.254.#{vlan}.2/30#SERVICE-TRANSIT-#{fw_suffix}")
                        .add_ip("169.254.#{vlan}.6/30#GW-#{left.name}#SERVICE-TRANSIT-#{fw_suffix}")
                        .add_ip("2602:ffea:1:7dd:#{vlan}::6/126#SERVICE-TRANSIT-#{fw_suffix}#GW-#{left.name}")
                        .add_route_from_tags("#INTERNET", "#FANOUT-#{fw_suffix}-GW"),
              'firewalls' => fws+['net-forward', 'ssh-srv', 'icmp-ping', 'block'],
              "host" => left,
              "remote" => region.interfaces.find(left, "v24").address,
              "any" => true
            }
        )
end

def mam_actions(region)
  {
  "rt-ab-de" => lambda do |my, net, peers|
    mam_ipsec_connection(region, my, peers[:de], "DE", net[:block])
  end,
  "rt-ab-us" => lambda do |my, net, peers|
    mam_ipsec_connection(region, my, peers[:us], "US", net[:block])
  end,
  "rt-wl-mgt" => lambda do |my, net, peers|
    mam_ipsec_connection(region, my, peers[:de], "DE", net[:block], net[:ipsec_fws])
  end,
  "rt-mam-wl-us" => lambda do |my, net, peers|
    mam_ipsec_connection(region, my, peers[:us], "US", net[:block])
  end,
  "rt-wl-printer" => lambda do |my, net, peers|
    # add backroute
    adr = region.interfaces.find("rt-wl-printer", "v24").address
    Construqt::Tags.find("#WL-PRINTABLE-NET").each do |iface|
      via = iface.host.interfaces.find_by_name("v24").address.first_ipv4
      iface.address.v4s.each do |dst|
        adr.add_route(dst.network.to_string, via.to_s)
      end
    end
  end
  }
end


class Aiccu
  include Construqt::Util::Chainable
  attr_reader :name
  attr_accessor :services
  chainable_attr :username
  chainable_attr :password
  def initialize(name)
    @name = name
  end
end

def mam_wl_rt(region, peers)
  region.services.add(
   Aiccu.new("AICCU").username(AICCU_DE["username"]).password(AICCU_DE["password"])
  )
  region.resources.add_file(<<MODULES, Construqt::Resources::Rights::root_0644, "odroid.modules", "etc", "modules")
loop
lp
rtc
libcrc32c
xt_multiport
nf_conntrack_ipv4
nf_defrag_ipv4
nf_conntrack
iptable_filter
ip_tables
x_tables
af_key
gre
tun
nf_conntrack_ipv6
nf_defrag_ipv6
ip6table_filter
ip6_tables
bonding
8021q
MODULES
  mal_wl_printer = region.hosts.add("wl-printer", "flavour" => "unknown") do |printer|
     printer.id = printer.configip = Construqt::HostId.create do |my|
       my.interfaces << region.interfaces.add_device(printer, "eth", "mtu" => 1500,
                                                     "default_name" => "ether",
                                                     "address" => region.network.addresses.add_ip("192.168.208.208/24"))
    end
  end
  mam_wl_rt = region.hosts.add("mam-wl-rt",
                               "flavour" => "ubuntu",
                               "files" => [region.resources.find("odroid.modules")]) do |host|
    region.interfaces.add_device(host, "lo", "mtu" => "9000",
                                 :description=>"#{host.name} lo",
                                 "address" => region.network.addresses.add_ip(Construqt::Addresses::LOOOPBACK))
    eth0 = region.interfaces.add_device(host, "eth0", "mtu" => 1500)
    host.configip = host.id ||= Construqt::HostId.create do |my|
      my.interfaces << region.interfaces.add_bridge(host, "br24", "mtu" => 1500,
                               "interfaces" => [region.interfaces.add_vlan(host, "eth0.24",
                                                "vlan_id" => 24,
                                                "mtu" => 1500,
                                                "interface" => eth0)],
                               "address" => region.network.addresses.add_ip("192.168.0.200/24")
                                                                    .add_route("0.0.0.0/0", "192.168.0.1"))
    end
    # 66,67 service
    # 202-207 router
    [66,68,202,203,206,207,208].each do |vlan|
      region.interfaces.add_bridge(host, "br#{vlan}", "mtu" => 1500,
                                   "interfaces" => [
                                    region.interfaces.add_vlan(host, "eth0.#{vlan}",
                                                     "vlan_id" => vlan,
                                                     "mtu" => 1500,
                                                     "interface" => eth0)])
    end
  end
  rts = {}
  wifi_vlans = []
  region.hosts.add('mam-ap', "flavour" => "mikrotik") do |ap|
    wlan1 = region.interfaces.add_wlan(ap, "wlan1",
                                  "mtu" => 1500,
                                  "default_name" => "wlan1",
                                  "band" => "2ghz-b/g/n",
                                  "channel_width" => "20/40mhz-Ce",
                                  "country" => "germany",
                                  "mode" => "ap-bridge",
                                  "rx_chain" => "0,1",
                                  "tx_chain" => "0,1",
                                  "ssid" => Digest::SHA256.hexdigest("wlan1-germany-2ghz-b/g/n")[0..12],
                                  "psk" => Digest::SHA256.hexdigest(INTERNAL_PSK)[12..28],
                                  "hide_ssid" => true)

    wlan2 = region.interfaces.add_wlan(ap, "wlan2",
                                  "mtu" => 1500,
                                  "default_name" => "wlan2",
                                  "band" => "5ghz-a/n/ac",
                                  "channel_width" => "20/40/80mhz-Ceee",
                                  "country" => "germany",
                                  "frequency" => "auto",
                                  "frequency_mode" => "regulatory-domain",
                                  "mode" => "ap-bridge",
                                  "rx_chain" => "0,1,2",
                                  "tx_chain" => "0,1,2",
                                  "ssid" => Digest::SHA256.hexdigest("wlan1-germany-5ghz-a/n/ac")[0..12],
                                  "psk" => Digest::SHA256.hexdigest(INTERNAL_PSK)[12..28],
                                  "hide_ssid" => true)
    [
      { :name => "rt-mam-wl-de",   :fws => ['net-nat', "net-forward"], :ssid => "MAM-WL", :block => 202 }, # homenet
      { :name => "rt-mam-wl-de-6", :fws => ['net-nat', "net-forward"], :services => [], :block => 203, :action => lambda do |aiccu, internal_if|
          region.interfaces.add_device(aiccu, "sixxs", "mtu" => "1280",
                                       "dynamic" => true,
                                       "firewalls" => [ fw_sixxs ],
                                       "address" => region.network.addresses.add_ip("2001:6f8:900:2bf::2/64"))
          internal_if.services.push(region.services.find("RADVD"))
          internal_if.address.ips = internal_if.address.ips.select{|i| i.ipv4? }
          internal_if.address.add_ip("2001:6f8:900:82bf:#{internal_if.address.first_ipv4.to_s.split(".").join(":")}/64")
        end
      }, # aiccu
      { :name => "rt-mam-wl-us",  :fws => ["net-forward"], :tag => "#SERVICE-NET-US", :ssid => "MAM-WL-US", :ipsec => Resolv.getaddress("fanout-us.adviser.com"), :block => 68  },
      { :name => "rt-wl-mgt", :fws => ["net-forward"], :ipsec_fws => ["vpn-server-net"], :tag => "#SERVICE-NET-DE", :ipsec => Resolv.getaddress("fanout-de.adviser.com"), :block => 66 },
      { :name => "rt-ab-us", :fws => ["net-forward"], :tag => "#SERVICE-NET-US", :ipsec => Resolv.getaddress("fanout-us.adviser.com"), :block => 206 }, # airbnb-us
      { :name => "rt-ab-de", :fws => ["net-forward"], :tag => "#SERVICE-NET-DE", :ipsec => Resolv.getaddress("fanout-de.adviser.com"), :block => 207 },  # airbnb-de
      { :name => "rt-wl-printer", :fws => ["wl-printer"], :tag => "#MAM-WL-PRINTER", :block => 208 },
    ].each do |net|
      wifi_ifs = []
      if WIFI_PSKS[net[:name]]
        wifi_vlans += wifi_ifs = [
          {:freq => 24, :master_if => wlan1 },
          {:freq => 50, :master_if => wlan2 }
        ].map do |freq|
          ssid = "#{net[:ssid] || net[:name].sub(/^[a-zA-Z0-9]+-/,'')}-#{freq[:freq]}"
          simple_ssid = ssid.downcase.gsub(/[^0-9a-z]+/, '')
          wlan = region.interfaces.add_wlan(ap, "wl#{simple_ssid}",
                                  "mtu" => 1500,
                                  "vlan_id" => net[:block],
                                  "master_if" => freq[:master_if],
                                  "ssid" => ssid.upcase,
                                  "psk" => WIFI_PSKS[net[:name]])
        end
      end

      rts[net[:name]] = region.hosts.add(net[:name], "flavour" => "ubuntu", "mother" => mam_wl_rt,
                                         "lxc_deploy" => Construqt::Hosts::Lxc.new.aa_profile_unconfined
                                                          .restart.killstop.release("trusty")) do |host|
        region.interfaces.add_device(host, "lo", "mtu" => "9000",
                                     :description=>"#{host.name} lo",
                                     "address" => region.network.addresses.add_ip(Construqt::Addresses::LOOOPBACK))
        host.configip = host.id ||= Construqt::HostId.create do |my|
          my.interfaces << region.interfaces.add_device(host, "v24", "mtu" => 1500,
                "plug_in" => Construqt::Cables::Plugin.new.iface(mam_wl_rt.interfaces.find_by_name("br24")),
                'firewalls' => net[:fws] + ['service-transit-local', 'ssh-srv', 'icmp-ping', 'block'],
                'address' => region.network.addresses.add_ip("192.168.0.#{net[:block]}/24#WL-PRINTABLE-BACKBONE")
                                      .add_route_from_tags("#wl-printer", "#rt-wl-printer-v24")
                                      .add_route(net[:ipsec]||"0.0.0.0/0", "192.168.0.1"))
        end
        internal_if = region.interfaces.add_device(host, "v#{net[:block]}#WL-PRINTABLE-NET", "mtu" => 1500,
              "plug_in" => Construqt::Cables::Plugin.new.iface(mam_wl_rt.interfaces.find_by_name("br#{net[:block]}")),
              'address' => region.network.addresses
                      .add_ip("192.168.#{net[:block]}.1/24#INTERNAL-NET#NET-#{net[:name]}#{net[:tag]||""}",
                          "dhcp" => Construqt::Dhcp.new.start("192.168.#{net[:block]}.100")
                                                       .end("192.168.#{net[:block]}.200")
                                                       .domain(net[:name]))
                      .add_ip("2a01:4f8:d15:1190:192:168:#{net[:block]}:1/123#INTERNAL-NET"))
        net[:action] && net[:action].call(host, internal_if)
        wifi_ifs.each do |iface|
          region.cables.add(iface, mam_wl_rt.interfaces.find_by_name("br#{net[:block]}"))
        end
      end
      mam_actions(region)[net[:name]] && mam_actions(region)[net[:name]].call(rts[net[:name]], net, peers)
    end


    ether1 = region.interfaces.add_device(ap,  "ether1", "default_name" => "ether1",
                              'address' => region.network.addresses.add_ip("192.168.176.6/24"))
    region.cables.add(ether1, region.interfaces.find("mam-wl-rt", "eth0"))

    v66 =    region.interfaces.add_vlan(ap, "v66", "vlan_id" => 66,
              'interface' => ether1,
              'address' => region.network.addresses
                                         .add_ip("192.168.66.6/24")
                                         .add_route("0.0.0.0/0", "192.168.66.1"))

    ap.configip = ap.id = Construqt::HostId.create do |my|
       my.interfaces << region.interfaces.add_bridge(ap, "bridge-local", "mtu" => 1500,
                                                     "interfaces" => [ether1]+wifi_vlans)
    end
  end
end

