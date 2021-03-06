module Construqt
  module Flavour
    module Ubuntu
      class IpsecVpn < OpenStruct
        def initialize(cfg)
          super(cfg)
        end
        def build_config(host, iface)
          #puts ">>>>>>>>>>>>>>>>>>>>>>#{host.name} #{iface.name}"
          render_ipv6_proxy(iface)
          if iface.leftpsk
            self.host.result.add(self, render_psk(host, iface),
                                 Construqt::Resources::Rights::root_0600(Construqt::Resources::Component::IPSEC), "etc", "ipsec.secrets")
          end

          self.host.result.add(self, render_ikev1(host, iface), Construqt::Resources::Rights::root_0644(Construqt::Resources::Component::IPSEC), "etc", "ipsec.conf")
          self.host.result.add(self, render_ikev2(host, iface), Construqt::Resources::Rights::root_0644(Construqt::Resources::Component::IPSEC), "etc", "ipsec.conf")
        end

        def render_ipv6_proxy(iface)
          return unless iface.ipv6_proxy
          host.result.add(self, <<UPDOWN_SH, Construqt::Resources::Rights.root_0755, "etc", "ipsec.d", "#{iface.left_interface.name}-ipv6_proxy_updown.sh")
#!/bin/bash
if [ $PLUTO_VERB = "up-client-v6" ]
then
	ipaddr=$(echo $PLUTO_PEER_CLIENT | sed 's|/.*$||')
  logger "proxy-up-client_ipv6=$ipaddr:#{iface.left_interface.name}"
  ip -6 neigh add proxy $ipaddr dev #{iface.left_interface.name}
	exit 0
fi
if [ $PLUTO_VERB = "down-client-v6" ]
then
	ipaddr=$(echo $PLUTO_PEER_CLIENT | sed 's|/.*$||')
  logger "proxy-down-client_ipv6=$ipaddr:#{iface.left_interface.name}"
  ip -6 neigh del proxy $ipaddr dev #{iface.left_interface.name}
	exit 0
fi

#(date;echo $@;env) >> /tmp/ipsec.log
exit 0
UPDOWN_SH
        end

        def render_psk(host, iface)
          out = []
          out << "## #{host.name}-#{iface.name}"
          iface.left_interface.address.ips.each do |ip|
            out << "#{ip.to_s} %any : PSK \"#{iface.leftpsk}\""
          end
          out.join("\n")
        end

        def render_ikev1(host, iface)
          conn = OpenStruct.new
          conn.keyexchange = "ikev1"
          conn.leftauth = "psk"
          conn.left = [iface.left_interface.address.first_ipv4,iface.left_interface.address.first_ipv6].compact.join(",")
          conn.leftid = host.region.network.fqdn(host.name)
          conn.leftsubnet = "0.0.0.0/0,2000::/3"
          if iface.ipv6_proxy
            conn.leftupdown = "/etc/ipsec.d/#{iface.left_interface.name}-ipv6_proxy_updown.sh"
            conn.rightupdown = "/etc/ipsec.d/#{iface.left_interface.name}-ipv6_proxy_updown.sh"
          end
          conn.right = "%any"
          conn.rightsourceip = iface.right_address.ips.map{|i| i.network.to_string}.join(",")
          conn.rightauth = "psk"
          if iface.auth_method == :radius
            conn.rightauth2 = "xauth-radius"
          else
            conn.rightauth2 = "xauth"
          end
          conn.rightsendcert = "never"
          conn.auto = "add"
          render_conn(host, iface, conn)
        end

        def render_ikev2(host, iface)
          conn = OpenStruct.new
          conn.keyexchange = "ikev2"
          conn.leftauth = "pubkey"
          if iface.leftcert
            conn.leftcert = iface.leftcert.name
          end
          conn.left = [iface.left_interface.address.first_ipv4,iface.left_interface.address.first_ipv6].compact.join(",")
          conn.leftid = host.region.network.fqdn(host.name)
          conn.leftsubnet = "0.0.0.0/0,2000::/3"
          if iface.ipv6_proxy
            conn.leftupdown = "/etc/ipsec.d/#{iface.left_interface.name}-ipv6_proxy_updown.sh"
            conn.rightupdown = "/etc/ipsec.d/#{iface.left_interface.name}-ipv6_proxy_updown.sh"
          end
          conn.right = "%any"
          conn.rightsourceip = iface.right_address.ips.map{|i| i.network.to_string}.join(",")
          conn.rightauth = "eap-mschapv2"
          conn.eap_identity = "%any"
          conn.auto = "add"
          render_conn(host, iface, conn)

        end


        def render_conn(host, iface, conn)
          out = ["conn #{host.name}-#{iface.name}-#{conn.keyexchange}"]
          conn.to_h.each do |k,v|
            out << Util.indent("#{k}=#{v}", 3)
          end
          out.join("\n")
        end
      end
    end
  end
end
