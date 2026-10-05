# hex-lab bootstrap — paste once via Winbox (MAC) after a clean reset.
# Creates only the access layer; everything else is managed by OpenTofu.
# This is the template — bootstrap.local.rsc (git-ignored) has the real password.

/system identity set name=hex-lab

# --- OOB management on ether3 ---------------------------------------------
/ip address add address=192.168.88.1/24 interface=ether3 comment="OOB management"
/ip pool add name=oob-pool ranges=192.168.88.10-192.168.88.20
/ip dhcp-server add name=oob-dhcp interface=ether3 address-pool=oob-pool lease-time=1h
/ip dhcp-server network add address=192.168.88.0/24 gateway=192.168.88.1 dns-server=192.168.88.1
/ip dns set servers=1.1.1.1,9.9.9.9 allow-remote-requests=yes

# --- HTTPS REST API for OpenTofu (self-signed) -----------------------------
/certificate add name=tf-api common-name=hex-lab days-valid=3650
/certificate sign tf-api
/ip service set www-ssl certificate=tf-api
/ip service enable www-ssl

# --- admin user (LAST: disabling admin may drop the current session) -------
:if ([:len [/user find where name="ben"]] = 0) do={ /user add name=ben password="<CHANGE_ME>" group=full comment="lab admin" }
:if ([:len [/user find where name="admin"]] > 0) do={ /user disable [/user find where name="admin"] }
:put "bootstrap complete"
