#!/usr/bin/env python3
"""Local TCP tunnels to larasrouter's Postgres and Valkey for a GUI client.

The Mac cannot reach 10.10.20.21:5432 / 10.10.20.23:6381 (the router lets only the
K3s worker through), and the containers take no SSH from the Mac. Each local
connection starts `ssh root@<node> pct exec <ct> -- bash` whose /dev/tcp opens the
connection FROM INSIDE the container to its own address, the path pg_hba and
Valkey already allow. The bytes are relayed untouched, so TLS runs end to end
between the GUI and the server. Listens on 127.0.0.1 only. Ctrl-C stops it.
"""
import socket
import subprocess
import sys
import threading

# name: (local port, ssh target, container id, address inside the container, port)
TUNNELS = {
    "db": (15432, "root@10.10.10.12", 130, "10.10.20.21", 5432),
    "redis": (16381, "root@10.10.10.13", 132, "10.10.20.23", 6381),
}


def pump(read, write, close):
    try:
        while True:
            data = read(65536)
            if not data:
                break
            write(data)
    except OSError:
        pass
    finally:
        close()


def handle(client, node, ct, host, port):
    remote = f"exec 3<>/dev/tcp/{host}/{port}; cat <&3 & cat >&3; wait"
    p = subprocess.Popen(
        ["ssh", "-T", "-o", "BatchMode=yes", node, f"pct exec {ct} -- bash -c '{remote}'"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
    )

    def close_all():
        for f in (lambda: client.shutdown(socket.SHUT_RDWR), client.close, p.stdin.close, p.terminate):
            try:
                f()
            except OSError:
                pass

    threading.Thread(target=pump, args=(client.recv, p.stdin.write, close_all), daemon=True).start()
    pump(p.stdout.read, client.sendall, close_all)


def serve(name):
    port, node, ct, host, rport = TUNNELS[name]
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(8)
    print(f"{name}: 127.0.0.1:{port} -> {host}:{rport} inside CT {ct}", flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c, node, ct, host, rport), daemon=True).start()


if __name__ == "__main__":
    names = sys.argv[1:] or list(TUNNELS)
    bad = [n for n in names if n not in TUNNELS]
    if bad:
        sys.exit(f"usage: {sys.argv[0]} [db] [redis]  (unknown: {bad})")
    for n in names[1:]:
        threading.Thread(target=serve, args=(n,), daemon=True).start()
    try:
        serve(names[0])
    except KeyboardInterrupt:
        pass
