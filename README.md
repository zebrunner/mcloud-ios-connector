# Zebrunner Device Connector

The Zebrunner Device Connector is a lightweight Docker image that exposes an iOS device to WebDriverAgent (WDA) clients. It connects to `usbmuxd`, checks device availability, mounts the Developer Disk Image, starts WDA when needed, and monitors the WDA status endpoint.

The image is based on Alpine and runs on `linux/amd64` only (it contains the amd64 build of [go-ios](https://github.com/danielpaulus/go-ios) 1.3.2).

Everything the image build downloads is pinned: the base image by version and digest, the Alpine packages by version (all of them are in the `main` and `community` repositories of the pinned release, no `edge/testing`), and go-ios by its SHA-256. Alpine drops the old revisions of a package from its release repositories, so a failing `apk add` after a security update means the pinned versions in the `Dockerfile` need a bump (the installed ones are checked by `make docker`).

## Build

Build the image from the repository root:

```bash
docker build --platform linux/amd64 --tag mcloud-ios-connector:local .
```

## Configuration

Set these environment variables when starting the container. `DEVICE_UDID` is required. The entrypoint validates it and the numeric variables (`POLLING_SEC`, `USBMUXD_PORT`, `WDA_PORT`, `MJPEG_PORT`, `WDA_WAIT_TIMEOUT`, `DEVICE_UNAVAILABLE_TIMEOUT` must be non-negative integers) and `HOST_OS` before anything is started.

| Variable | Default | Description |
| --- | --- | --- |
| `DEVICE_UDID` | empty | UDID of the iOS device to connect (required). |
| `HOST_OS` | `LINUX` | Host platform, case-insensitive: `LINUX` or `DARWIN` (what mcloud-agent passes; `MACOS` is the same as `DARWIN`), any other value is an error. On Linux the container starts go-ncm and the go-ios tunnel for iOS 17+, installs WDA from `WDA_FILE` if needed and starts it. On macOS (`DARWIN`) WDA must be installed and started by the host, the container only forwards its ports. |
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
| `POLLING_SEC` | `5` | Delay between device and service readiness checks. |
| `DEVICE_UNAVAILABLE_TIMEOUT` | `600` | How long in seconds the device may stay unavailable (for example unpaired) over the container restarts before the entrypoint exits with `0` and stops them. `0` restarts forever. |
| `LOGGER_LEVEL` | `INFO` | Minimum log level: `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `DEBUG` | `false` | Intercept script exit and wait for `DEBUG_TIMEOUT` seconds. |
| `DEBUG_TIMEOUT` | `3600` | Debug exit pause duration in seconds. |
| `VERBOSE` | `false` | Enable Bash command tracing. |

When WDA is not installed on the device, make the IPA available at `WDA_FILE` (for example, by mounting it into the container). The container also needs access to the device or to the configured usbmuxd service; the required device and network mounts depend on the host and deployment environment. The built-in usbmuxd needs USB access, the iOS 17+ tunnel reads the pair records from `/var/lib/lockdown`, and the Developer Disk Images are downloaded into `/opt/zebrunner/devimages/` on demand.

## Shared tunnel

For iOS newer than 17.4.0 the go-ios tunnel runs in userspace mode (no TUN device is needed) and is shared with the other containers of the device: the tunnel API listens on all the interfaces (`GO_IOS_AGENT_HOST=0.0.0.0`, port `60105`) and the userspace tunnel port (`60106` for one device) is forwarded by socat from the address of the container. Another container on the same docker network uses the tunnel with `GO_IOS_AGENT_HOST=connector` (the network alias of this container), so it needs no tunnel of its own. iOS 17.0 - 17.4.0 keeps the kernel tunnel (go-ncm), which is not shared.

## Device type

The entrypoint reads `DeviceClass` of the device (`iPhone`, `iPod`, `iPad` or `AppleTV`) and logs the type: `Phone`, `Tablet` or `tvOS`. For Apple TV it runs the tvOS runner of WDA (`WebDriverAgentRunner_tvOS.xctest`, the bundle ids are the same as for iOS) unless `XCTEST_CONFIG` is set. Apple TV on a Linux host also needs go-ncm and the tunnel to work with the device, which is not verified with real hardware.

## Exit codes and health

- Exit code `0` means an unrecoverable problem that a restart does not fix: invalid configuration, a busy `USBMUXD_PORT`, an unavailable usbmuxd, a Developer Image that cannot be mounted, WDA that cannot be installed or started (a WDA that cannot be launched because of an invalid code signature is not retried), or a device that has been unavailable for longer than `DEVICE_UNAVAILABLE_TIMEOUT`.
- Exit code `1` asks for a restart: the device is not available (for up to `DEVICE_UNAVAILABLE_TIMEOUT` seconds in total, the time is kept in `/tmp/zebrunner/device-unavailable-since` and survives the restarts of the same container), go-ncm or the tunnel is not ready, port forwarding is broken, or WDA is not responding.
- WDA start and port forwarding run in the background: their failure is passed to the entrypoint, which exits with the same code (checked while waiting for WDA and then every 33 seconds).
- The image healthcheck requests `http://${WDA_HOST}:${WDA_PORT}/status` and expects HTTP 200.
- Set `DEBUG=true` to keep the container alive for `DEBUG_TIMEOUT` seconds after the entrypoint exits, and `LOGGER_LEVEL=DEBUG` or `VERBOSE=true` for more output.

## Development

`make help` lists the targets, `make check` runs all of them as CI does (every step runs, the failed ones fail the target):

| Target | What it checks |
| --- | --- |
| `make lint` | `tests/lint.sh`: yamllint, actionlint, hadolint, pymarkdown, `bash -n`, ShellCheck and shfmt (style of `.editorconfig`), every env var of the `Dockerfile` documented in this README, the text file checks of CONVENTIONS.md. The tools are installed into `.venv` from `tests/requirements-lint.txt`; hadolint comes from `brew install hadolint` on macOS. |
| `make test` | The static checks of the repository (`tests/repo_test.sh`: the pins of the `Dockerfile`, the Dependabot configuration) and the tests of `util/logger.sh`, `util/debug.sh` and `entrypoint.sh`: configuration validation, usbmuxd, device polling, Developer Image, WDA installation, start and port forwarding with their recovery and retry limits, Linux iOS 17+ (go-ncm, tunnel), WDA health checks, the `DEBUG` and `VERBOSE` modes. The tools are stubs (`ios`, `nc`, `socat`, `curl`, ...), so no docker and no iOS device are needed, but bash 4+ is (on macOS `brew install bash`). |
| `make docker` | `tests/image_test.sh`: builds the image (`linux/amd64`, `IMAGE` overrides its tag, `REBUILD=true` rebuilds it), checks its contents, the installed versions of the pinned packages, configuration, configuration validation and the entrypoint startup without a device. |

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
