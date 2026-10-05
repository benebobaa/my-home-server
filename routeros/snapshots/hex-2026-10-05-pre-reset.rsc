# 2026-10-05 16:41:16 by RouterOS 7.23.7
# software id = 3LRP-021M
#
# model = RB750Gr3
# serial number = CC210DFD49E2
/interface bridge
add comment="the LAN" name=bridge
/interface list
add comment="the inside" name=LAN
add comment="the outside" name=WAN
/ip pool
add name=lan-pool ranges=192.168.88.10-192.168.88.254
/ip dhcp-server
add address-pool=lan-pool interface=bridge lease-time=10m name=lan-dhcp
/interface bridge port
add bridge=bridge interface=ether2
add bridge=bridge interface=ether3
add bridge=bridge interface=ether4
add bridge=bridge interface=ether5
/ip neighbor discovery-settings
set discover-interface-list=LAN
/interface list member
add interface=bridge list=LAN
add interface=ether1 list=WAN
/ip address
add address=192.168.88.1/24 comment="the router's own place" interface=bridge \
    network=192.168.88.0
/ip dhcp-client
add comment="ask upstream for an address" interface=ether1 name=client1
/ip dhcp-server lease
add address=192.168.88.254 client-id=1:9c:69:d3:cc:f0:18 mac-address=\
    9C:69:D3:CC:F0:18 server=lan-dhcp
/ip dhcp-server network
add address=192.168.88.0/24 dns-server=192.168.88.1 gateway=192.168.88.1
/ip dns
set allow-remote-requests=yes servers=1.1.1.1,8.8.8.8
/ip dns static
add address=192.168.88.1 name=router.lan type=A
/ip firewall filter
add action=accept chain=input comment="replies to conversations we started" \
    connection-state=established,related,untracked
add action=drop chain=input comment="nonsense in, gone" connection-state=\
    invalid
add action=accept chain=input comment="let the world ping me" protocol=icmp
add action=drop chain=input comment="nothing else may reach me from outside" \
    in-interface-list=!LAN
add action=fasttrack-connection chain=forward comment=\
    "fast lane for known traffic" connection-state=established,related
add action=accept chain=forward comment="let replies through" \
    connection-state=established,related,untracked
add action=drop chain=forward comment="nonsense through, gone" \
    connection-state=invalid
add action=drop chain=forward comment=\
    "no uninvited guests reaching your devices" connection-nat-state=!dstnat \
    connection-state=new in-interface-list=WAN
/ip firewall nat
add action=masquerade chain=srcnat comment="wear the WAN address going out" \
    out-interface-list=WAN
/ip service
set ftp disabled=yes
set telnet disabled=yes
set api disabled=yes
/system clock
set time-zone-name=Asia/Jakarta
/system identity
set name=hex-lab
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN
