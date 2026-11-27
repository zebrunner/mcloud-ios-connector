# Zebrunner MCloud iOS Connector

The Zebrunner MCloud iOS Connector is a lightweight Docker image that exposes an iOS device to WebDriverAgent (WDA) clients. It connects to `usbmuxd`, checks device availability, mounts the Developer Disk Image, starts WDA when needed, and monitors the WDA status endpoint. It is the only point of contact with the device: the other containers of the device (Appium, STF) take usbmuxd (`USBMUXD_PORT`), WDA (`WDA_PORT`, `MJPEG_PORT`) and the shared tunnel from it, whatever the connection of the device is (see [Connections](#connections)).

## Image contents

The image is based on Alpine and is built for `linux/amd64` and `linux/arm64` (it contains the build of the platform of [go-ios](https://github.com/danielpaulus/go-ios) 1.3.2, of [netmuxd](https://github.com/jkcoxson/netmuxd) 0.4.3 built for musl and of the `mcloud-ios` helper of `tools/mcloud-ios`). The image build also builds `usbmuxd` from the commit `2efa75a` of [libimobiledevice/usbmuxd](https://github.com/libimobiledevice/usbmuxd) (`1.1.1-71-g2efa75a`, the release 1.1.1 misses the recent iOS versions) and `go-ncm` from `cmd/cdc-ncm` of the go-ios 1.3.2 sources, both from archives with a sha256 checksum.

Everything the image build downloads is pinned: the base and the build images by version and digest, the Alpine packages by version (all of them are in the `main` and `community` repositories of the pinned release, no `edge/testing`), go-ios and the netmuxd sources by their SHA-256, the Go modules of the helper by `go.sum` and the crates of netmuxd by its `Cargo.lock`. Alpine drops the old revisions of a package from its release repositories, so a failing `apk add` after a security update means the pinned versions in the `Dockerfile` need a bump (the installed ones are checked by `make docker`).

The certificate `certs/apple-root-ca.crt` (Apple Root CA) is added to the CA bundle of the image: go-ios gets the personalized Developer Disk Image of iOS 17+ signed by the signing server of Apple (`https://gs.apple.com/TSS/controller`), whose certificate chains to Apple Root CA, which is not in the CA bundle of Alpine.

## Build

```bash
make build VERSION=2.0   # public.ecr.aws/zebrunner/mcloud-ios-connector:2.0 in the local docker
make push VERSION=2.0    # built by docker buildx and pushed: docker login public.ecr.aws first
```

`make build` builds the image for the platform of this machine, `make push` builds `linux/amd64` and `linux/arm64` (`PLATFORMS`) with `docker buildx` and pushes them as one multi-platform image. `IMAGE_REPO` sets another repository (e.g. `IMAGE_REPO=registry.example.com/mcloud-ios-connector`), `VERSION` is the tag and the
`org.opencontainers.image.version` label (`dev` by default, required by `push`). `make push` uses the buildx builder
`mcloud` (docker-container driver), which it creates once; another platform than the one of the machine needs QEMU
(`docker run --privileged --rm tonistiigi/binfmt --install all`).

The file `VERSION` is the release in work (bumped by hand after a release, CONVENTIONS.md#versions). The `publish` job of CI pushes the image of every merge into `develop` after all the checks passed: `public.ecr.aws/zebrunner/mcloud-ios-connector:<VERSION>-develop-<sha>` (7 characters of the commit) and `<VERSION>-develop-latest`, the newest commit of `develop`. Each platform is built on a runner of its own (arm64 on an arm64 runner) and pushed by digest, with the cache of GitHub Actions (`PUSH_OUTPUT` and `PUSH_CACHE` of `make push`), then the job merges them into the image.

## Run

mcloud-agent creates the container (`roles/common/files/zebrunner-farm`, `device-<name>-<udid>-connector`, where `<name>` is the name of the device in `mcloud-devices.txt`) on the docker network of the farm (`STF_DOCKER_NETWORK`); the STF and Appium containers of the device link to it as `connector`. A USB device of a Linux host:

```bash
docker run -d --name device-<name>-<udid>-connector --net infra --restart on-failure:<restarts> \
  --sysctl net.ipv6.conf.all.disable_ipv6=0 --cap-add NET_ADMIN --device /dev/net/tun \
  --device /dev/device-<name>-<udid>:/dev/bus/usb/<bus>/<device> \
  -e HOST_OS=LINUX -e DEVICE_CONNECTION=usb -e DEVICE_UDID=<udid> \
  -e WDA_BUNDLEID=com.facebook.WebDriverAgentRunner.xctrunner -e WDA_FILE=/tmp/zebrunner/WebDriverAgent.ipa \
  -v /path/to/WebDriverAgent.ipa:/tmp/zebrunner/WebDriverAgent.ipa \
  -v devimages_cache:/opt/zebrunner/devimages \
  -v device-<name>-<udid>-lockdown:/var/lib/lockdown \
  -v device-<name>-<udid>:/tmp/log \
  public.ecr.aws/zebrunner/mcloud-ios-connector:2.0
```

- `--device /dev/device-<name>-<udid>:/dev/bus/usb/<bus>/<device>`: the USB device for the usbmuxd of the container, the symlink of the udev rule of mcloud-agent passed at the path of its bus (`usb` on Linux only).
- `--cap-add NET_ADMIN --device /dev/net/tun --sysctl net.ipv6.conf.all.disable_ipv6=0`: go-ncm and the kernel tunnel of iOS 17.0 - 17.4.0 (a network interface, a TUN device, IPv6); mcloud-agent passes them to every connector of a Linux host.
- `/var/lib/lockdown`: the pair records (a `wireless` device is paired over USB once, see [Connections](#connections)) and the identity of the tunnel, a volume of the device so they survive a new container. `backup/` keeps a copy of the pair record of a USB device, see [Pair record backup](#pair-record-backup).
- `/opt/zebrunner/devimages`: the downloaded Developer Disk Images, one volume shared by the devices of the host.
- `/tmp/log`: the logs (WDA, the tunnel), the volume of the device shared with its Appium and uploader containers.
- `WDA_FILE`: the IPA of WDA, installed when the device has no WDA.
- Other connections: `wireless` and `proxy` add `-e DEVICE_CONNECTION=<connection> -e DEVICE_ADDRESS=<address>` (no USB device). On macOS (`-e HOST_OS=DARWIN`) Docker has no USB: there is no `--device`, `--cap-add` and `--sysctl`, a USB or wireless device is reached over the usbmuxd of the host (`-e USBMUXD_SOCKET_ADDRESS=host.docker.internal:2222`, relayed by mcloud-agent); a simulator adds `-e DEVICE_CONNECTION=ios-sim -e HOST_SSH_USER=<user> -e DEVICE_WDA_PORT=<port> -v <agent>/ssh/id_ed25519:/opt/zebrunner/ssh/id_ed25519:ro` and its `WDA_FILE` is a simulator build.
- No port is published: the other containers of the device reach usbmuxd (`USBMUXD_PORT`), WDA (`WDA_PORT`, `MJPEG_PORT`) and the shared tunnel on the docker network.

## Configuration

Set these environment variables when starting the container. `DEVICE_UDID` is required. The entrypoint validates the configuration before anything is started, logs every invalid variable and exits with `0`: `DEVICE_UDID`, `HOST_OS`, `DEVICE_CONNECTION`, `DEVICE_ADDRESS` (required for `proxy`, and for `wireless` without `USBMUXD_SOCKET_ADDRESS`), the non-negative integers `POLLING_SEC`, `USBMUXD_PORT`, `WDA_PORT`, `MJPEG_PORT`, `WDA_WAIT_TIMEOUT`, `DEVICE_UNAVAILABLE_TIMEOUT`, `DEVICE_WDA_PORT`, `DEVICE_MJPEG_PORT`, `WDA_FAILURES_BEFORE_REBOOT` (also not `0`) and `REBOOT_INTERVAL`, `ALLOW_REBOOT` (`true` or `false`), `WDA_BIND_ADDRESS` (`auto`, `all` or an IPv4 or IPv6 address); for `ios-sim` also `HOST_OS` (`DARWIN` only), `HOST_SSH_USER` (required), `HOST_SSH_PORT` and `HOST_SSH_PROXY_PORT` (non-negative integers).

| Variable | Default | Description |
| --- | --- | --- |
| `DEVICE_UDID` | empty | UDID of the iOS device or of the simulator to connect (required). The udid of a simulator is a UUID (`xcrun simctl list devices`), any other value is an error: it is a part of the commands run on the macOS host. |
| `DEVICE_CONNECTION` | `usb` | How the device is reached, case-insensitive: `usb`, `wireless`, `ios-sim` or `proxy`, see [Connections](#connections). |
| `DEVICE_ADDRESS` | empty | `wireless`: the IP address of the device (required without `USBMUXD_SOCKET_ADDRESS`); `proxy`: the host that publishes WDA (required). |
| `DEVICE_WDA_PORT` | `WDA_PORT` | `ios-sim` and `proxy`: the WDA port on the side of the device, unique for every simulator of a macOS host. |
| `DEVICE_MJPEG_PORT` | `MJPEG_PORT` | `ios-sim` and `proxy`: the MJPEG port on the side of the device, unique for every simulator of a macOS host. |
| `HOST_OS` | `LINUX` | Host platform, case-insensitive: `LINUX` or `DARWIN` (what mcloud-agent passes; `MACOS` is the same as `DARWIN`), any other value is an error. On Linux the container starts the go-ios tunnel for iOS 17+ of a USB device, and go-ncm for its kernel tunnel of iOS 17.0 - 17.4.0. On both of them it installs WDA from `WDA_FILE` if needed and starts it; on macOS a WDA already started by the host is used as is. |
| `USBMUXD_SOCKET_ADDRESS` | empty | External usbmuxd TCP address in `host:port` form. If unset, the container starts usbmuxd itself. |
| `USBMUXD_PORT` | `2222` | Local TCP port used to forward usbmuxd connections. |
| `WDA_FILE` | `/tmp/zebrunner/WebDriverAgent.ipa` | WDA IPA path used for installation on Linux when WDA is not already installed. |
| `WDA_BUNDLEID` | `com.facebook.WebDriverAgentRunner.xctrunner` | WDA application bundle identifier. `ios-sim`: letters, digits, `.` and `-` only, any other value is an error. |
| `TEST_RUNNER_BUNDLE_ID` | same as `WDA_BUNDLEID` | XCTest runner bundle identifier. |
| `XCTEST_CONFIG` | `WebDriverAgentRunner.xctest`, `WebDriverAgentRunner_tvOS.xctest` for Apple TV | XCTest configuration passed to `ios runwda`. The default depends on the detected device type, a value set manually is never replaced. |
| `DDI_DIR` | `/opt/zebrunner/ddi` | The folder of a checkout of [zebrunner/DeveloperDiskImage](https://github.com/zebrunner/DeveloperDiskImage) (a read-only mount, optional): the Developer Disk Images mounted before the ones go-ios downloads, see [Developer Disk Images](#developer-disk-images). |
| `WDA_HOST` | `localhost` | Host used by the WDA health checks. |
| `WDA_PORT` | `8100` | WDA HTTP port. |
| `MJPEG_PORT` | `8101` | WDA MJPEG port. |
| `WDA_BIND_ADDRESS` | `auto` | The address WDA listens on (`USE_IP` of WDA), case-insensitive: `auto` is `127.0.0.1` (the loopback of the device) for `usb` and for `ios-sim` with the default `HOST_SSH_HOST` (the loopback of the macOS host), every interface for `wireless`; `all` is every interface (the behaviour before); an IP address is used as is. See [WebDriverAgent address](#webdriveragent-address). |
| `WDA_WAIT_TIMEOUT` | `30` | Maximum time in seconds to wait for WDA to become healthy. |
| `ALLOW_REBOOT` | `false` | `true`: the device is rebooted when WDA can't start because testmanagerd of the device does not answer, see [WDA can't start: reboot](#wda-cant-start-reboot). Case-insensitive, any other value than `true` or `false` is an error. |
| `WDA_FAILURES_BEFORE_REBOOT` | `3` | The starts of the container in a row in which WDA can't start because of testmanagerd before the reboot (1 or more). |
| `REBOOT_INTERVAL` | `21600` | At most one reboot of the device per this many seconds: WDA that can't start again within it stops the restarts (`0`). |
| `WDA_LOG_FILE` | `/tmp/log/wda.log` | WDA log file. |
| `HOST_SSH_USER` | empty | `ios-sim`: the user of the macOS host (required). |
| `HOST_SSH_HOST` | `host.docker.internal` | `ios-sim`: the macOS host. |
| `HOST_SSH_PORT` | `22` | `ios-sim`: the ssh port of the macOS host (Remote Login). |
| `HOST_SSH_KEY` | `/opt/zebrunner/ssh/id_ed25519` | `ios-sim`: the private ssh key of the user (mounted, its public key is in `~/.ssh/authorized_keys` of the user). |
| `HOST_SSH_PROXY_PORT` | `22` | `ios-sim`: the port of the container relayed to the ssh of the host, the Appium container runs `xcrun` of the host through it. |
| `POLLING_SEC` | `5` | Delay between device and service readiness checks. |
| `DEVICE_UNAVAILABLE_TIMEOUT` | `600` | How long in seconds the device may stay unavailable (for example unpaired) or its Developer Image unmounted over the container restarts before the entrypoint exits with `0` and stops them. `0` restarts forever. |
| `IMAGE_VERSION` | the `VERSION` of the build | The version of the image in the first log line. |
| `LOGGER_LEVEL` | `INFO` | Minimum log level: `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `DEBUG` | `false` | Intercept script exit and wait for `DEBUG_TIMEOUT` seconds. |
| `DEBUG_TIMEOUT` | `3600` | Debug exit pause duration in seconds. |
| `VERBOSE` | `false` | Enable Bash command tracing. |
| `RUST_LOG` | `info` | `wireless` on Linux: the log level of netmuxd (`error`, `warn`, `info`, `debug`, `trace`). |

When WDA is not installed on the device, make the IPA available at `WDA_FILE` (for example, by mounting it into the container). The container also needs access to the device or to the configured usbmuxd service; the required device and network mounts depend on the host and deployment environment. The built-in usbmuxd needs USB access, the iOS 17+ tunnel reads the pair records from `/var/lib/lockdown`, and the Developer Disk Images come from `DDI_DIR` or are downloaded into `/opt/zebrunner/devimages/` on demand (see [Developer Disk Images](#developer-disk-images)).

## Connections

`DEVICE_CONNECTION` selects how the connector reaches the device. The other containers of the device always use the connector the same way, only `ios-sim` and `proxy` have no usbmuxd (`WIRELESS=true` of the Appium and STF containers).

| Connection | Device | Linux host | macOS host |
| --- | --- | --- | --- |
| `usb` | iPhone, iPad, Apple TV HD (USB-C) | usbmuxd of the container (the USB device is passed in), go-ncm and the kernel tunnel for iOS 17.0 - 17.4.0, the userspace tunnel after 17.4.0 | usbmuxd of the host (`USBMUXD_SOCKET_ADDRESS`, Docker has no USB), the userspace tunnel after iOS 17.4.0 over it |
| `wireless` | iPhone, iPad, Apple TV over Wi-Fi (lockdown over the network) | netmuxd of the container with the device added by `DEVICE_ADDRESS` (no mDNS, the docker network does not pass it) and its pair record in `/var/lib/lockdown` | usbmuxd of the host, it knows the network devices paired with the Mac |
| `ios-sim` | iOS, iPadOS and tvOS simulators | - | `xcrun simctl` of the host over ssh (Remote Login): boot, WDA install from `WDA_FILE` (a simulator build: a `.app` folder or its `.zip`) and launch on `DEVICE_WDA_PORT` |
| `proxy` | any device whose WDA is started by another tool | WDA and MJPEG of `DEVICE_ADDRESS` are relayed | the same |

In all the connections the container keeps WDA healthy and exits with `1` (restart) when it stops answering.

A wireless device must be paired with the farm first: connect it over USB once (`DEVICE_CONNECTION=usb`, the pair record is kept in the `/var/lib/lockdown` volume) and allow its lockdown over Wi-Fi: `docker exec <connector> mcloud-ios wifi-connections <udid> on`. iOS 17.0 - 17.4.0 has no tunnel without the USB of a Linux host, there WDA must be started outside the container. The tunnel of a wireless device after iOS 17.4.0 and an Apple TV 4K (tvOS 17+ pairs with RemotePairing and a PIN, which is not supported yet) are not verified with real hardware: for such an Apple TV start WDA with another tool and use `proxy`.

For a simulator the macOS host needs Xcode with the runtime of the simulator and Remote Login (System Settings, General, Sharing) for the user; mcloud-agent generates the key pair. The ssh port of the host is relayed by the connector (`HOST_SSH_PROXY_PORT`), so the Appium container of the simulator runs `xcrun` of the host through the connector too.

## Network

The docker network of the farm (`STF_DOCKER_NETWORK` of mcloud-agent, `infra` by default) is trusted: the ports of the connector have no authentication and listen on all the interfaces of the container, so every container on that network reaches usbmuxd (`USBMUXD_PORT`, `2222`: lockdown, the pair records, app installs), WDA and MJPEG (`WDA_PORT`, `MJPEG_PORT`) and, after iOS 17.4.0, the go-ios tunnel API (`60105`, also `/shutdown` and `DELETE /tunnel/<udid>`) and the tunnel port of every iOS device of the host. Attach only the containers of the farm to it ([the analysis](https://github.com/zebrunner/mcloud-ios-connector/issues/121)).

## WebDriverAgent address

WDA and its MJPEG server have no authentication, so the connector makes WDA listen on the loopback (`USE_IP=127.0.0.1` of `ios runwda`, `SIMCTL_CHILD_USE_IP` of a simulator) wherever the connector reaches it there: then no other host of the network of the device (its Wi-Fi, another device of the farm) reaches WDA, the other containers of the device still reach it through the connector (`WDA_PORT`, `MJPEG_PORT`). `WDA_BIND_ADDRESS=auto` (the default) chooses the address by the connection:

| Connection | How the connector reaches WDA | `auto` |
| --- | --- | --- |
| `usb` (any iOS version, Linux and macOS) | `ios forward` through usbmuxd (of the container or of the macOS host): the device opens the connection on its loopback, also for iOS 17+ with the tunnel (the forwarded ports do not use the tunnel) | `127.0.0.1` |
| `ios-sim` | the relays of the connector reach the macOS host through `host.docker.internal`: Docker Desktop connects to the loopback of the host | `127.0.0.1`; every interface with another `HOST_SSH_HOST` (a remote Mac reaches the network address of the host) |
| `wireless` | netmuxd (Linux) and the usbmuxd of the macOS host connect to the network address of the device | every interface |
| `proxy` | WDA is started by another tool | does not apply |

- WDA bound to `127.0.0.1` does not answer on the Wi-Fi address of the device and on the address of the iOS 17+ tunnel: a tool that reaches WDA there (not through the connector) needs `WDA_BIND_ADDRESS=all` (the behaviour before) or the address it uses.
- The MJPEG server of WDA follows `USE_IP` since [appium/WebDriverAgent 16.15.3](https://github.com/appium/WebDriverAgent/pull/1299) and in [zebrunner/WebDriverAgent](https://github.com/zebrunner/WebDriverAgent/pull/20) after `11.4.1`: an older build of WDA keeps `MJPEG_PORT` on every interface of the device, rebuild it to bind both ports.
- A WDA started outside the container (macOS: Xcode or a script of the host) and the one of `proxy` listen where their tool starts them.
- The log tells the address before the start of WDA: `WebDriverAgent listens on 127.0.0.1 only (USE_IP, WDA_BIND_ADDRESS=auto)`; the WDA log (`WDA_LOG_FILE`) has `Using custom binding IP address: 127.0.0.1`.

## Shared tunnel

For iOS newer than 17.4.0 the go-ios tunnel runs in userspace mode (no TUN device is needed, also over the usbmuxd of a macOS host and over netmuxd) and is shared with the other containers of the device: the tunnel API listens on all the interfaces (`GO_IOS_AGENT_HOST=0.0.0.0`, port `60105`) and the userspace tunnel port (`60106` for one device) is forwarded by socat from the address of the container. Another container on the same docker network uses the tunnel with `GO_IOS_AGENT_HOST=connector` (the network alias of this container), so it needs no tunnel of its own. iOS 17.0 - 17.4.0 keeps the kernel tunnel (go-ncm), which is not shared.

## Device type

The entrypoint reads `DeviceClass` of the device (`iPhone`, `iPod`, `iPad` or `AppleTV`) and logs the type: `Phone`, `Tablet` or `tvOS`. For Apple TV it runs the tvOS runner of WDA (`WebDriverAgentRunner_tvOS.xctest`, the bundle ids are the same as for iOS) unless `XCTEST_CONFIG` is set. A simulator gets its type from its runtime and device type (`tvOS`, `iPad`). An Apple TV has no USB configuration of NCM: on Linux over USB it needs tvOS newer than 17.4.0 (the userspace tunnel, no go-ncm), tvOS 17.0 - 17.4.0 has no tunnel there. Apple TV is not verified with real hardware.

## Developer Disk Images

The developer services of a device (WDA, the apps, the screenshots) need its Developer Disk Image mounted. Mount a checkout of [zebrunner/DeveloperDiskImage](https://github.com/zebrunner/DeveloperDiskImage) (the images of Xcode, a fork of doronz88/DeveloperDiskImage; mcloud-agent clones it) read-only at `DDI_DIR`, e.g. `-v /opt/DeveloperDiskImage:/opt/zebrunner/ddi:ro`, and the connector mounts its image with `ios image mount --path=<image>`:

| Device | The image of `DDI_DIR` |
| --- | --- |
| iOS before 17 | `DeveloperDiskImages/<version>/DeveloperDiskImage.dmg` with its `.signature`: the folder of the exact version (`16.4.1`), else of `major.minor` (`16.4`), else the newest lower one of the same major (`12.4` for `12.5.7`) |
| iOS 17+ | `PersonalizedImages/Xcode_iOS_DDI_Personalized` (personalized for the device by go-ios with the signing server of Apple) |
| tvOS 17+ (Apple TV) | `PersonalizedImages/Xcode_tvOS_DDI_Personalized`: the iOS image has no identity of an Apple TV |

Without `DDI_DIR`, without the image of the device (e.g. tvOS before 17) or when its mount fails, the connector runs `ios image auto` as before: go-ios downloads the image into the `/opt/zebrunner/devimages/` cache (before 17 from a GitHub repository of its catalog, 17+ the image of Xcode 15.4 from `deviceboxhq.com`) and mounts it. The log tells the source of the mounted image (`Developer Image source:`). go-ios mounts the personalized images with the image mounter only, the devices newer than the `BuildManifest.plist` of the image (which need its Cryptex variant) are not supported by either source.

## Pair record backup

The usbmuxd of the container removes the pair record of a device on any SSL error of its preflight (`The stored pair record for device <udid> is invalid. Removing.`), also when the USB connection drops in the TLS handshake (a worn cable or port) and the device still trusts the host. Without the record the device needs a person at its Trust dialog. So for a `usb` device with the usbmuxd of the container (no `USBMUXD_SOCKET_ADDRESS`):

- After the device answered (`ios info`), its record `/var/lib/lockdown/<udid>.plist` is copied to `/var/lib/lockdown/backup/<udid>.plist` (only when it differs, e.g. after a new pairing). usbmuxd, netmuxd and go-ios read only the files of `/var/lib/lockdown`, not the folder.
- A missing record is restored from the copy before usbmuxd starts; a record removed during the start is restored and the container restarts (`1`) with a new usbmuxd. The log says `The pair record of '<udid>' was removed (usbmuxd: an SSL error of StartSession, e.g. a USB drop); restored from the backup of <date> (<n>/3).`
- The device refuses a record it no longer trusts (erased, "Reset Location & Privacy", `ClearPasscode` of an MDM), and usbmuxd removes it again. After 3 restores without an answer of the device the copy is renamed `backup/<udid>.plist.rejected-<time>` and not restored again. The log then asks to unlock the device and accept the Trust dialog (`docker exec <connector> ios pair --udid=<udid>`), and the device is unavailable within `DEVICE_UNAVAILABLE_TIMEOUT`.

The copy holds the private key of the host for the device, like the record: the folder has mode `700`, the copy `600`. To restore it by hand: `docker exec <connector> cp /var/lib/lockdown/backup/<udid>.plist /var/lib/lockdown/` (a `.rejected-*` copy is copied to `/var/lib/lockdown/<udid>.plist` the same way) and `docker restart <connector>`.

## WDA can't start: reboot

Sometimes testmanagerd of a device stops answering, e.g. after a mass restart of the containers: WDA hangs at `loading Accessibility` (`/tmp/log/wda.log`), `ios runwda` fails with `cannot initiate a control session with capabilities: Timed out waiting for response` and every new container fails the same way. Only a reboot of the device helps. The connector counts the starts of the container with this failure in a row (`/tmp/zebrunner/wda-hang-starts`, it survives the restarts of the container; a WDA that answers resets it). After `WDA_FAILURES_BEFORE_REBOOT` of them:

- `ALLOW_REBOOT=false` (the default): nothing else changes, the log says `Device reboot is recommended`.
- `ALLOW_REBOOT=true` (`usb` and `wireless`): `ios reboot`, then exit `1`; the containers of the device are created again when it reconnects. A WDA that keeps failing does not reboot it in a loop: within `REBOOT_INTERVAL` after a reboot (its time is kept in `/var/lib/lockdown/reboot/<udid>`, the lockdown volume survives a new container) the connector exits with `0`, the device needs a person.
- iOS 17+ with a passcode may lose its pairing on a reboot (usbmuxd removes the pair record): such a device is rebooted only when its pair record has a backup (see [Pair record backup](#pair-record-backup)), otherwise the log asks to reboot it by hand.

## Exit codes and health

- Exit code `0` means an unrecoverable problem that a restart does not fix: invalid configuration, a busy `USBMUXD_PORT`, an unavailable usbmuxd, a Developer Image that has not been mounted for longer than `DEVICE_UNAVAILABLE_TIMEOUT`, WDA that cannot be installed or fails to start 10 times in a row (a run of WDA of more than a minute was a start; a WDA that cannot be launched because of an invalid code signature is not retried), a device that has been unavailable for longer than `DEVICE_UNAVAILABLE_TIMEOUT`, WDA that can't start again within `REBOOT_INTERVAL` after a reboot of the device (`ALLOW_REBOOT`), a simulator unknown to the host, an ssh key refused by the host or missing.
- Exit code `1` asks for a restart: the device is not available (not found, or `ios info` times out: without its iOS version and type the device is not started) or its Developer Image is not mounted, e.g. its download failed (for up to `DEVICE_UNAVAILABLE_TIMEOUT` seconds in total each, the time is kept in `/tmp/zebrunner/device-unavailable-since` and `/tmp/zebrunner/image-mount-failing-since` and survives the restarts of the same container), the pair record was restored from its backup (see [Pair record backup](#pair-record-backup)), go-ncm or the tunnel is not ready, port forwarding or a relay is broken, the macOS host is not reachable over ssh, the simulator does not boot or WDA does not launch on it, or WDA is not responding (also after a reboot of the device by `ALLOW_REBOOT`; with it WDA that fails to start 10 times in a row because of testmanagerd restarts the container until the reboot).
- WDA start, port forwarding and the relays run in the background: their failure is passed to the entrypoint, which exits with the same code (checked while waiting for WDA and then every 33 seconds).
- `docker stop` (`SIGTERM`) ends the entrypoint (PID 1 of the container) at once, also in a wait: it stops the background processes and exits with `0`; a long foreground command (e.g. the download of a Developer Image) ends first.
- The image healthcheck requests `http://${WDA_HOST}:${WDA_PORT}/status` (GET, the newer WDA builds answer 404 to HEAD) and expects HTTP 200.
- Set `DEBUG=true` to keep the container alive for `DEBUG_TIMEOUT` seconds after the entrypoint exits, and `LOGGER_LEVEL=DEBUG` or `VERBOSE=true` for more output.

## Development

`make help` lists the targets, `make check` runs all of them as CI does (every step runs, the failed ones fail the target):

| Target | What it checks |
| --- | --- |
| `make lint` | `tests/lint.sh`: yamllint, actionlint, hadolint, pymarkdown, `bash -n`, ShellCheck and shfmt (style of `.editorconfig`), every env var of the `Dockerfile` documented in this README, gofmt and go vet of `tools/mcloud-ios` (when Go is installed), the text file checks of CONVENTIONS.md. The tools are installed into `.venv` from `tests/requirements-lint.txt`; hadolint comes from `brew install hadolint` on macOS. |
| `make test` | The static checks of the repository (`tests/repo_test.sh`: the pins of the `Dockerfile`, the Dependabot configuration) and the tests of `util/logger.sh`, `util/debug.sh` and `entrypoint.sh`: configuration validation, usbmuxd, device polling, Developer Image (the images of `DDI_DIR` and the download), WDA installation, start and port forwarding with their recovery and retry limits, Linux iOS 17+ (go-ncm, tunnel), the userspace tunnel of macOS, WDA health checks, the connections (`wireless` with netmuxd, `proxy`, `ios-sim` over ssh), `SIGTERM`, the `DEBUG` and `VERBOSE` modes. The tools are stubs (`ios`, `nc`, `socat`, `curl`, `ssh`, `netmuxd`, ...), so no docker and no iOS device are needed, but bash 4+ and jq are (on macOS `brew install bash`). `tests/helper_test.sh`: `go test` of `tools/mcloud-ios` with a fake usbmuxd (the reply of netmuxd and its timeout), skipped without Go. |
| `make docker` | `tests/image_test.sh`: builds the image (`PLATFORM`: `linux/amd64` by default or `linux/arm64`, `IMAGE` overrides its tag, `REBUILD=true` rebuilds it), checks its contents, the installed versions of the pinned packages, configuration, configuration validation, the entrypoint startup without a device and `docker stop`. |

Every test script prints its checks and writes JUnit XML into `JUNIT_DIR` when it is set.

The GitHub Actions workflow `.github/workflows/ci.yml` runs the same `lint`, `test` and `docker` jobs on pushes and pull requests to `develop`, `main` and `master`.

Dependabot (`.github/dependabot.yml`) opens weekly pull requests for the GitHub Actions and the images of the `Dockerfile`. The linters of `tests/requirements-lint.txt` are the shared ones of mcloud-conventions, updated there and synced; the Alpine packages, go-ios, netmuxd and usbmuxd are updated by hand.

The conventions of the style, the formatting and the tooling of this repository are in [CONVENTIONS.md](CONVENTIONS.md), the same in all the MCloud docker image repositories.

## Support

Feel free to support the development with a [**donation**](https://www.paypal.com/donate/?hosted_button_id=MNHYYCYHAKUVA) for the next improvements.

<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="https://github.com/zebrunner/zebrunner/raw/master/docs/img/zebrunner_intro.png"></a>
</p>

## License

[Apache License 2.0](LICENSE)
