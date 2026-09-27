# UKL–MQTT controlled comparison

## Configurations

| # | Kernel image | Config | Publisher | `launch.sh` mode |
|---|---|---|---|---|
| 1 | `artifacts/upstream-default/bzImage` | `x86_64_defconfig` + `kvm_guest.config` | user space | `user` |
| 2 | `artifacts/upstream-uklcfg/bzImage` | UKL project config, UKL symbols removed | user space | `user` |
| 3 | `artifacts/ukl/vmlinuz` | UKL (base, performance options off) | user space | `user` |
| 4 | `artifacts/ukl/vmlinuz` (same file as 3) | UKL (base, performance options off) | embedded (`/UKL`) | `ukl` |

All four boot `artifacts/common-initrd.cpio.xz` through `launcher/launch.sh`: same QEMU options,
kernel command line, guest resources and network route (virtio-net → tap → `br-mqtt` → broker on 192.168.150.1).
The publisher source (`publisher/publisher.c`) is the thesis version; both builds use `-g -O2`.

## Build order

1. `build/in_container.sh build/fetch_sources.sh`
2. `build/in_container.sh build/build_ukl.sh`
3. `build/in_container.sh build/build_upstream.sh`
4. `build/in_container.sh build/build_publisher_user.sh`
5. On the host: `build/build_initrd.sh`
6. On the host, once per boot: `sudo launcher/setup_bridge.sh`, then start Mosquitto on 192.168.150.1:1883
7. Smoke test each row of the table, e.g.
   `sudo QEMU_CPUS=2 launcher/launch.sh artifacts/ukl/vmlinuz artifacts/common-initrd.cpio.xz ukl smoke-01 results/raw/smoke-01.serial`

Every kernel `.config`, the diffs between them and all SHA256 sums are written to `configs/` and `artifacts/`.
