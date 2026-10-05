# 2026-09-15 12:25:43 by RouterOS 7.23.7
# software id = 3LRP-021M
#
# model = RB750Gr3
# serial number = CC210DFD49E2
/ip pool
add name=oob-pool ranges=192.168.88.10-192.168.88.20
/ip dhcp-server
add address-pool=oob-pool interface=ether3 lease-time=1h name=oob-dhcp
/ip address
add address=192.168.88.1/24 comment="OOB management" interface=ether3 \
    network=192.168.88.0
/ip dhcp-server network
add address=192.168.88.0/24 dns-server=192.168.88.1 gateway=192.168.88.1
/ip dns
set allow-remote-requests=yes servers=1.1.1.1,9.9.9.9
/ip service
set www-ssl certificate=tf-api disabled=no
/system identity
set name=hex-lab
