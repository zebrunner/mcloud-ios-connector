# Zebrunner Device Connector

The Zebrunner Device Connector is a lightweight Docker image that exposes an iOS device to WebDriverAgent (WDA) clients. It connects to `usbmuxd`, checks device availability, mounts the Developer Disk Image, starts WDA when needed, and monitors the WDA status endpoint. It is the only point of contact with the device: the other containers of the device (Appium, STF) take usbmuxd (`USBMUXD_PORT`), WDA (`WDA_PORT`, `MJPEG_PORT`) and the shared tunnel from it, whatever the connection of the device is (see [Connections](#connections)).

The image is based on Alpine and is built for `linux/amd64` and `linux/arm64` (it contains the build of the platform of [go-ios](https://github.com/danielpaulus/go-ios) 1.3.2, of [netmuxd](https://github.com/jkcoxson/netmuxd) 0.4.3 built for musl and of the `mcloud-ios` helper of `tools/mcloud-ios`). The image build also builds `usbmuxd` from the commit `2efa75a` of [libimobiledevice/usbmuxd](https://github.com/libimobiledevice/usbmuxd) (`1.1.1-71-g2efa75a`, the release 1.1.1 misses the recent iOS versions) and `go-ncm` from `cmd/cdc-ncm` of the go-ios 1.3.2 sources, both from archives with a sha256 checksum.

Everything the image build downloads is pinned: the base and the build images by version and digest, the Alpine packages by version (all of them are in the `main` and `community` repositories of the pinned release, no `edge/testing`), go-ios and the netmuxd sources by their SHA-256, the Go modules of the helper by `go.sum` and the crates of netmuxd by its `Cargo.lock`. Alpine drops the old revisions of a package from its release repositories, so a failing `apk add` after a security update means the pinned versions in the `Dockerfile` need a bump (the installed ones are checked by `make docker`).

## Build

```bash
make build VERSION=3.1   # public.ecr.aws/zebrunner/mcloud-ios-connector:3.1 in the local docker
make push VERSION=3.1    # built by docker buildx and pushed: docker login public.ecr.aws first
```

`make build` builds the image for the platform of this machine, `make push` builds `linux/amd64` and `linux/arm64` (`PLATFORMS`) with `docker buildx` and pushes them as one multi-platform image. `IMAGE_REPO` sets another repository (e.g. `IMAGE_REPO=registry.example.com/mcloud-ios-connector`), `VERSION` is the tag and the
`org.opencontainers.image.version` label (`dev` by default, required by `push`). `make push` uses the buildx builder
`mcloud` (docker-container driver), which it creates once; another platform than the one of the machine needs QEMU
(`docker run --privileged --rm tonistiigi/binfmt --install all`).

## Configuration

Set these environment variables when starting the container. `DEVICE_UDID` is required. The entrypoint validates it and the numeric variables (`POLLING_SEC`, `USBMUXD_PORT`, `WDA_PORT`, `MJPEG_PORT`, `WDA_WAIT_TIMEOUT`, `DEVICE_UNAVAILABLE_TIMEOUT` must be non-negative integers) and `HOST_OS` before anything is started.

| Variable | Default | Description |
| --- | --- | --- |
| `DEVICE_UDID` | empty | UDID of the iOS device or of the simulator to connect (required). |
| `DEVICE_CONNECTION` | `usb` | How the device is reached, case-insensitive: `usb`, `wireless`, `ios-sim` or `proxy`, see [Connections](#connections). |
| `DEVICE_ADDRESS` | empty | `wireless`: the IP address of the device (required without `USBMUXD_SOCKET_ADDRESS`); `proxy`: the host that publishes WDA (required). |
| `DEVICE_WDA_PORT` | `WDA_PORT` | `ios-sim` and `proxy`: the WDA port on the side of the device, unique for every simulator of a macOS host. |
| `DEVICE_MJPEG_PORT` | `MJPEG_PORT` | `ios-sim` and `proxy`: the MJPEG port on the side of the device, unique for every simulator of a macOS host. |
| `HOST_OS` | `LINUX` | Host platform, case-insensitive: `LINUX` or `DARWIN` (what mcloud-agent passes; `MACOS` is the same as `DARWIN`), any other value is an error. On Linux the container starts go-ncm and the go-ios tunnel for iOS 17+ of a USB device. On both of them it installs WDA from `WDA_FILE` if needed and starts it; on macOS a WDA already started by the host is used as is. |
| `USBMUXD_SOCKET_ADDRESS` | empty | External usbmuxd TCP address in `host:port` form. If unset, the container starts usbmuxd itself. |
| `USBMUXD_PORT` | `2222` | Local TCP port used to forward usbmuxd connections. |
| `WDA_FILE` | `/tmp/zebrunner/WebDriverAgent.ipa` | WDA IPA path used for installation on Linux when WDA is not already installed. |
| `WDA_BUNDLEID` | `com.facebook.WebDriverAgentRunner.xctrunner` | WDA application bundle identifier. |
| `TEST_RUNNER_BUNDLE_ID` | same as `WDA_BUNDLEID` | XCTest runner bundle identifier. |
| `XCTEST_CONFIG` | `WebDriverAgentRunner.xctest`, `WebDriverAgentRunner_tvOS.xctest` for Apple TV | XCTest configuration passed to `ios runwda`. The default depends on the detected device type, a value set manually is never replaced. |
| `WDA_HOST` | `localhost` | Host used by the WDA health checks. |
| `WDA_PORT` | `8100` | WDA HTTP port. |
| `MJPEG_PORT` | `8101` | WDA MJPEG port. |
| `WDA_WAIT_TIMEOUT` | `30` | Maximum time in seconds to wait for WDA to become healthy. |
| `WDA_LOG_FILE` | `/tmp/log/wda.log` | WDA log file. |
| `HOST_SSH_USER` | empty | `ios-sim`: the user of the macOS host (required). |
| `HOST_SSH_HOST` | `host.docker.internal` | `ios-sim`: the macOS host. |
| `HOST_SSH_PORT` | `22` | `ios-sim`: the ssh port of the macOS host (Remote Login). |
| `HOST_SSH_KEY` | `/opt/zebrunner/ssh/id_ed25519` | `ios-sim`: the private ssh key of the user (mounted, its public key is in `~/.ssh/authorized_keys` of the user). |
| `HOST_SSH_PROXY_PORT` | `22` | `ios-sim`: the port of the container relayed to the ssh of the host, the Appium container runs `xcrun` of the host through it. |
| `POLLING_SEC` | `5` | Delay between device and service readiness checks. |
| `DEVICE_UNAVAILABLE_TIMEOUT` | `600` | How long in seconds the device may stay unavailable (for example unpaired) over the container restarts before the entrypoint exits with `0` and stops them. `0` restarts forever. |
| `LOGGER_LEVEL` | `INFO` | Minimum log level: `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `DEBUG` | `false` | Intercept script exit and wait for `DEBUG_TIMEOUT` seconds. |
| `DEBUG_TIMEOUT` | `3600` | Debug exit pause duration in seconds. |
| `VERBOSE` | `false` | Enable Bash command tracing. |

When WDA is not installed on the device, make the IPA available at `WDA_FILE` (for example, by mounting it into the container). The container also needs access to the device or to the configured usbmuxd service; the required device and network mounts depend on the host and deployment environment. The built-in usbmuxd needs USB access, the iOS 17+ tunnel reads the pair records from `/var/lib/lockdown`, and the Developer Disk Images are downloaded into `/opt/zebrunner/devimages/` on demand.

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

## Shared tunnel

For iOS newer than 17.4.0 the go-ios tunnel runs in userspace mode (no TUN device is needed, also over the usbmuxd of a macOS host and over netmuxd) and is shared with the other containers of the device: the tunnel API listens on all the interfaces (`GO_IOS_AGENT_HOST=0.0.0.0`, port `60105`) and the userspace tunnel port (`60106` for one device) is forwarded by socat from the address of the container. Another container on the same docker network uses the tunnel with `GO_IOS_AGENT_HOST=connector` (the network alias of this container), so it needs no tunnel of its own. iOS 17.0 - 17.4.0 keeps the kernel tunnel (go-ncm), which is not shared.

## Device type

The entrypoint reads `DeviceClass` of the device (`iPhone`, `iPod`, `iPad` or `AppleTV`) and logs the type: `Phone`, `Tablet` or `tvOS`. For Apple TV it runs the tvOS runner of WDA (`WebDriverAgentRunner_tvOS.xctest`, the bundle ids are the same as for iOS) unless `XCTEST_CONFIG` is set. A simulator gets its type from its runtime and device type (`tvOS`, `iPad`). Apple TV is not verified with real hardware.

## Exit codes and health

- Exit code `0` means an unrecoverable problem that a restart does not fix: invalid configuration, a busy `USBMUXD_PORT`, an unavailable usbmuxd, a Developer Image that cannot be mounted, WDA that cannot be installed or started (a WDA that cannot be launched because of an invalid code signature is not retried), a device that has been unavailable for longer than `DEVICE_UNAVAILABLE_TIMEOUT`, a simulator unknown to the host, an ssh key refused by the host or missing.
- Exit code `1` asks for a restart: the device is not available (for up to `DEVICE_UNAVAILABLE_TIMEOUT` seconds in total, the time is kept in `/tmp/zebrunner/device-unavailable-since` and survives the restarts of the same container), go-ncm or the tunnel is not ready, port forwarding or a relay is broken, the macOS host is not reachable over ssh, the simulator does not boot or WDA does not launch on it, or WDA is not responding.
- WDA start, port forwarding and the relays run in the background: their failure is passed to the entrypoint, which exits with the same code (checked while waiting for WDA and then every 33 seconds).
- The image healthcheck requests `http://${WDA_HOST}:${WDA_PORT}/status` (GET, the newer WDA builds answer 404 to HEAD) and expects HTTP 200.
- Set `DEBUG=true` to keep the container alive for `DEBUG_TIMEOUT` seconds after the entrypoint exits, and `LOGGER_LEVEL=DEBUG` or `VERBOSE=true` for more output.

## Development

`make help` lists the targets, `make check` runs all of them as CI does (every step runs, the failed ones fail the target):

| Target | What it checks |
| --- | --- |
| `make lint` | `tests/lint.sh`: yamllint, actionlint, hadolint, pymarkdown, `bash -n`, ShellCheck and shfmt (style of `.editorconfig`), every env var of the `Dockerfile` documented in this README, gofmt and go vet of `tools/mcloud-ios` (when Go is installed), the text file checks of CONVENTIONS.md. The tools are installed into `.venv` from `tests/requirements-lint.txt`; hadolint comes from `brew install hadolint` on macOS. |
| `make test` | The static checks of the repository (`tests/repo_test.sh`: the pins of the `Dockerfile`, the Dependabot configuration) and the tests of `util/logger.sh`, `util/debug.sh` and `entrypoint.sh`: configuration validation, usbmuxd, device polling, Developer Image, WDA installation, start and port forwarding with their recovery and retry limits, Linux iOS 17+ (go-ncm, tunnel), the userspace tunnel of macOS, WDA health checks, the connections (`wireless` with netmuxd, `proxy`, `ios-sim` over ssh), the `DEBUG` and `VERBOSE` modes. The tools are stubs (`ios`, `nc`, `socat`, `curl`, `ssh`, `netmuxd`, ...), so no docker and no iOS device are needed, but bash 4+ and jq are (on macOS `brew install bash`). |
| `make docker` | `tests/image_test.sh`: builds the image (`PLATFORM`: `linux/amd64` by default or `linux/arm64`, `IMAGE` overrides its tag, `REBUILD=true` rebuilds it), checks its contents, the installed versions of the pinned packages, configuration, configuration validation and the entrypoint startup without a device. |

Every test script prints its checks and writes JUnit XML into `JUNIT_DIR` when it is set.

The GitHub Actions workflow `.github/workflows/ci.yml` runs the same `lint`, `test` and `docker` jobs on pushes and pull requests to `develop`, `main` and `master`.

Dependabot (`.github/dependabot.yml`) opens weekly pull requests for the GitHub Actions, the base image of the `Dockerfile` and the linters of `tests/requirements-lint.txt`. The Alpine packages are updated by hand.

The conventions of the style, the formatting and the tooling of this repository are in [CONVENTIONS.md](CONVENTIONS.md), the same in all the MCloud docker image repositories.

## Support

Feel free to support the development with a [**donation**](https://www.paypal.com/donate/?hosted_button_id=MNHYYCYHAKUVA) for the next improvements.

<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="https://github.com/zebrunner/zebrunner/raw/master/docs/img/zebrunner_intro.png"></a>
</p>

## License

[Apache License 2.0](LICENSE)
