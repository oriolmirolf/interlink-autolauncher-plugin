ubuntu@worker:~/interlink-autolauncher-plugin$ sudo bash scripts/worker/setup-plugin-bridge.sh 192.168.0.98 8001
==> Installing socat
Hit:1 http://nova.clouds.archive.ubuntu.com/ubuntu noble InRelease
Hit:2 http://security.ubuntu.com/ubuntu noble-security InRelease
Hit:3 http://nova.clouds.archive.ubuntu.com/ubuntu noble-updates InRelease
Hit:4 http://nova.clouds.archive.ubuntu.com/ubuntu noble-backports InRelease
Hit:5 https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v1.30/deb  InRelease
Reading package lists... Done
Reading package lists... Done
Building dependency tree... Done
Reading state information... Done
socat is already the newest version (1.8.0.0-4build3).
curl is already the newest version (8.5.0-2ubuntu10.6).
The following packages were automatically installed and are no longer required:
  bridge-utils dns-root-data dnsmasq-base pigz ubuntu-fan
Use 'sudo apt autoremove' to remove them.
0 upgraded, 0 newly installed, 0 to remove and 67 not upgraded.
==> Writing systemd unit /etc/systemd/system/worker-plugin-bridge.service
==> Reloading and starting service
==> Verifying UNIX socket exists
srw-rw-rw- 1 root root 0 Aug 11 12:48 /var/run/interlink/.plugin.sock
==> Health check through UNIX socket
{"status":"ok"}
OK.
ubuntu@worker:~/interlink-autolauncher-plugin$ bash scripts/tests/smoke.plugin.sh unix
==> Health
{"status":"ok"}
==> Create (busybox sleep)
[{"PodUID":"smoke-uid","PodJID":"cadc93f2d3a8068be0166e2f5efe3c6c2ef0c1fdd4f74b4afc8e24404a4fa396"}]
==> Status (GET)
curl: (22) The requested URL returned error: 422

==> Logs (GET, tail=200)
(logs endpoint returned non-2xx; container may have already exited)

==> Delete
"OK"OK
