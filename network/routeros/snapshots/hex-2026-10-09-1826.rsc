# 2026-10-09 18:26:38 by RouterOS 7.23.7
# software id = 3LRP-021M
#
# model = RB750Gr3
# serial number = CC210DFD49E2
/interface ethernet
set [ find default-name=ether1 ] mtu=1492
/interface vlan
add comment=MGMT interface=ether5 name=vlan10-mgmt vlan-id=10
add comment=SERVERS interface=ether5 name=vlan20-servers vlan-id=20
add comment=DMZ interface=ether5 name=vlan25-dmz vlan-id=25
add comment=LAB interface=ether5 name=vlan30-lab vlan-id=30
add comment=TRUSTED interface=ether5 name=vlan40-trusted vlan-id=40
add comment=IOT/GUEST interface=ether5 name=vlan50-iot vlan-id=50
/interface list
add comment="the outside" name=WAN
add comment="the lab side" name=LAN
add comment="every interface except the household side" exclude=WAN include=\
    all name=NOT-WAN
/ip pool
add name=oob-pool ranges=192.168.88.10-192.168.88.20
add name=pool30-lab ranges=10.10.30.100-10.10.30.199
add name=pool50-iot ranges=10.10.50.100-10.10.50.199
add name=pool40-trusted ranges=10.10.40.100-10.10.40.199
/queue simple
add comment="DMZ <-> internet cap (upload/download)" dst=ether1 max-limit=\
    50M/50M name=dmz-internet target=10.10.25.0/24
/snmp community
set [ find default=yes ] addresses=127.0.0.1/32 comment=\
    "factory default, disabled (managed by OpenTofu)" disabled=yes \
    read-access=no
add addresses=10.10.10.16/32 authentication-protocol=SHA1 comment=\
    "Prometheus snmp_exporter (CT 120 monitoring)" encryption-protocol=AES \
    name=monitoring security=private
/ip neighbor discovery-settings
set discover-interface-list=NOT-WAN
/ip settings
set rp-filter=strict
/interface list member
add interface=ether1 list=WAN
add interface=vlan40-trusted list=LAN
add interface=vlan50-iot list=LAN
add interface=vlan25-dmz list=LAN
add interface=vlan30-lab list=LAN
add interface=vlan20-servers list=LAN
add interface=vlan10-mgmt list=LAN
/ip address
add address=192.168.88.1/24 comment="OOB management" interface=ether3 \
    network=192.168.88.0
add address=192.168.99.1/29 comment="switch management (native VLAN)" \
    interface=ether5 network=192.168.99.0
add address=10.10.50.1/24 comment="IOT gateway" interface=vlan50-iot network=\
    10.10.50.0
add address=10.10.40.1/24 comment="TRUSTED gateway" interface=vlan40-trusted \
    network=10.10.40.0
add address=10.10.20.1/24 comment="SERVERS gateway" interface=vlan20-servers \
    network=10.10.20.0
add address=10.10.30.1/24 comment="LAB gateway" interface=vlan30-lab network=\
    10.10.30.0
add address=10.10.25.1/24 comment="DMZ gateway" interface=vlan25-dmz network=\
    10.10.25.0
add address=10.10.10.1/24 comment="MGMT gateway" interface=vlan10-mgmt \
    network=10.10.10.0
/ip dhcp-client
add comment="uplink to the Biznet router" interface=ether1 name=client1 \
    use-peer-dns=no
/ip dhcp-server
# Interface not running
add address-pool=oob-pool interface=ether3 lease-time=1h name=oob-dhcp
add address-pool=pool50-iot interface=vlan50-iot lease-time=12h name=\
    dhcp50-iot
add address-pool=pool30-lab interface=vlan30-lab lease-time=12h name=\
    dhcp30-lab
add address-pool=pool40-trusted interface=vlan40-trusted lease-time=12h name=\
    dhcp40-trusted
/ip dhcp-server network
add address=10.10.30.0/24 dns-server=10.10.30.1 gateway=10.10.30.1
add address=10.10.40.0/24 dns-server=10.10.40.1 gateway=10.10.40.1
add address=10.10.50.0/24 dns-server=10.10.50.1 gateway=10.10.50.1
add address=192.168.88.0/24 dns-server=192.168.88.1 gateway=192.168.88.1
/ip dns
set allow-remote-requests=yes servers=1.1.1.1,9.9.9.9
/ip dns static
add address=10.10.10.12 comment="managed by OpenTofu" name=pve2.home.arpa \
    type=A
add address=10.10.10.15 comment="managed by OpenTofu" name=admin-gw.home.arpa \
    type=A
add address=10.10.10.13 comment="managed by OpenTofu" name=pve3.home.arpa \
    type=A
add address=10.10.10.1 comment="managed by OpenTofu" name=hex.home.arpa type=\
    A
add address=192.168.99.2 comment="managed by OpenTofu" name=switch.home.arpa \
    type=A
add address=10.10.10.16 comment="managed by OpenTofu" name=\
    monitoring.home.arpa type=A
/ip firewall address-list
add address=192.168.18.0/24 comment=\
    "Biznet household LAN - never reachable from the lab" list=biznet-lan
add address=10.10.10.0/24 comment=MGMT list=admin-src
add address=10.10.10.15 comment="Tailscale admin gateway (CT 101 on pve3)" \
    list=admin-gw
add address=10.10.40.0/24 comment=TRUSTED list=admin-src
add address=192.168.99.0/29 comment="switch management / P1 recovery segment" \
    list=admin-src
add address=100.64.0.0/10 comment="CGNAT shared space" list=non-public
add address=169.254.0.0/16 comment=link-local list=non-public
add address=192.168.0.0/16 comment="RFC1918 (incl. the Biznet household LAN)" \
    list=non-public
add address=10.0.0.0/8 comment="RFC1918 (incl. Biznet CGNAT internals)" list=\
    non-public
add address=172.16.0.0/12 comment=RFC1918 list=non-public
add address=10.10.10.16 comment="Prometheus (CT 120 on pve2)" list=monitoring
add address=192.168.99.2 comment="SG108E switch" list=monitored
add address=10.10.0.0/16 comment="lab VLANs" list=monitored
/ip firewall filter
add action=accept chain=input comment="replies to conversations we started" \
    connection-state=established,related
add action=drop chain=input comment="nonsense in, gone" connection-state=\
    invalid
add action=accept chain=input comment="let the world ping me" protocol=icmp
add action=accept chain=input comment="DNS + DHCP for the lab" dst-port=53,67 \
    in-interface-list=LAN protocol=udp
add action=accept chain=input comment="DNS over TCP" dst-port=53 \
    in-interface-list=LAN protocol=tcp
add action=accept chain=input comment="admin: SSH, REST/WebFig, Winbox" \
    dst-port=22,443,8291 protocol=tcp src-address-list=admin-src
add action=accept chain=input comment="OOB recovery port" in-interface=ether3
add action=accept chain=input comment="monitoring: SNMP" dst-port=161 \
    in-interface=vlan10-mgmt protocol=udp src-address-list=monitoring
add action=drop chain=input comment="drop everything else"
add action=fasttrack-connection chain=forward comment=\
    "offload established flows (not the DMZ)" connection-state=\
    established,related dst-address=!10.10.25.0/24 src-address=!10.10.25.0/24
add action=accept chain=forward comment="replies to conversations we started" \
    connection-state=established,related
add action=drop chain=forward connection-state=invalid
add action=drop chain=forward comment=\
    "DMZ: no outbound SMTP (spam from the household IP)" dst-port=25 log=yes \
    log-prefix=dmz-smtp out-interface-list=WAN protocol=tcp src-address=\
    10.10.25.0/24
add action=drop chain=forward comment=\
    "DMZ: no private/CGNAT destinations via WAN (ISP internals)" \
    dst-address-list=non-public log=yes log-prefix=dmz-private \
    out-interface-list=WAN src-address=10.10.25.0/24
add action=accept chain=forward comment="TRUSTED to internal" dst-address=\
    10.10.0.0/16 in-interface=vlan40-trusted src-address=10.10.40.0/24
add action=accept chain=forward comment="DMZ pinhole: K3s VM to Postgres" \
    dst-address=10.10.20.21 dst-port=5432 in-interface=vlan25-dmz \
    out-interface=vlan20-servers protocol=tcp src-address=10.10.25.20
add action=accept chain=forward comment="admin-gw to internal" dst-address=\
    10.10.0.0/16 in-interface=vlan10-mgmt src-address-list=admin-gw
add action=accept chain=forward comment="admin to the switch management UI" \
    dst-address=192.168.99.2 dst-port=80,443 protocol=tcp src-address-list=\
    admin-src
add action=accept chain=forward comment="monitoring: ping lab VLANs + switch" \
    dst-address-list=monitored in-interface=vlan10-mgmt protocol=icmp \
    src-address-list=monitoring
add action=drop chain=forward comment=\
    "lab must not reach Biznet/household LAN" dst-address-list=biznet-lan \
    out-interface-list=WAN
add action=drop chain=forward comment="default deny between lab VLANs" \
    in-interface-list=LAN out-interface-list=LAN
add action=accept chain=forward comment="internet for the lab" \
    in-interface-list=LAN out-interface-list=WAN
add action=drop chain=forward comment="default drop"
/ip firewall mangle
add action=change-mss chain=forward comment=\
    "PPPoE upstream (1492): clamp TCP MSS" new-mss=clamp-to-pmtu \
    out-interface-list=WAN protocol=tcp tcp-flags=syn
/ip firewall nat
add action=masquerade chain=srcnat comment="share the Biznet address" \
    out-interface-list=WAN
/ip service
set ftp disabled=yes
set telnet disabled=yes
set www disabled=yes
set www-ssl certificate=tf-api disabled=no
set api disabled=yes
/snmp
set contact="homelab operator" enabled=yes location="home rack"
/system clock
set time-zone-name=Asia/Jakarta
/system identity
set name=hex-lab
/system ntp client
set enabled=yes
/system ntp client servers
add address=0.id.pool.ntp.org
add address=1.id.pool.ntp.org
add address=time.cloudflare.com
/tool bandwidth-server
set enabled=no
/tool mac-server
set allowed-interface-list=NOT-WAN
/tool mac-server mac-winbox
set allowed-interface-list=NOT-WAN
