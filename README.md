# Zebrunner Device Connector

The Zebrunner Device Connector is a lightweight Docker image that exposes an iOS
device to WebDriverAgent (WDA) clients. It connects to `usbmuxd`, checks device
availability, mounts the Developer Disk Image, starts WDA when needed, and
monitors the WDA status endpoint.

The image is based on Alpine and runs on `linux/amd64` only (it contains the
amd64 build of [go-ios](https://github.com/danielpaulus/go-ios) 1.3.2).

## Build

Build the image from the repository root:

```sh
docker build --tag mcloud-ios-connector:local .
```

## Configuration

Set these environment variables when starting the container. `DEVICE_UDID` is
required. The entrypoint validates it and the numeric variables (`POLLING_SEC`,
`USBMUXD_PORT`, `WDA_PORT`, `MJPEG_PORT`, `WDA_WAIT_TIMEOUT` must be
non-negative integers) before anything is started.

| Variable | Default | Description |
| --- | --- | --- |
| `DEVICE_UDID` | empty | UDID of the iOS device to connect (required). |
| `HOST_OS` | `LINUX` | Host platform: `LINUX` or `MACOS` (any other value behaves as `MACOS`). On Linux the container starts go-ncm and the go-ios tunnel for iOS 17+, installs WDA from `WDA_FILE` if needed and starts it. On macOS WDA must be installed and started by the host, the container only forwards its ports. |
| `USBMUXD_SOCKET_ADDRESS` | empty | External usbmuxd TCP address in `host:port` form. If unset, the container starts usbmuxd itself. |
| `USBMUXD_PORT` | `2222` | Local TCP port used to forward usbmuxd connections. |
| `WDA_FILE` | `/tmp/zebrunner/WebDriverAgent.ipa` | WDA IPA path used for installation on Linux when WDA is not already installed. |
| `WDA_BUNDLEID` | `com.facebook.WebDriverAgentRunner.xctrunner` | WDA application bundle identifier. |
| `TEST_RUNNER_BUNDLE_ID` | same as `WDA_BUNDLEID` | XCTest runner bundle identifier. |
| `XCTEST_CONFIG` | `WebDriverAgentRunner.xctest` | XCTest configuration passed to `ios runwda`. |
| `WDA_HOST` | `localhost` | Host used by the WDA health checks. |
| `WDA_PORT` | `8100` | WDA HTTP port. |
| `MJPEG_PORT` | `8101` | WDA MJPEG port. |
| `WDA_WAIT_TIMEOUT` | `30` | Maximum time in seconds to wait for WDA to become healthy. |
| `WDA_LOG_FILE` | `/tmp/log/wda.log` | WDA log file. |
| `POLLING_SEC` | `5` | Delay between device and service readiness checks. |
| `LOGGER_LEVEL` | `INFO` | Minimum log level: `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `DEBUG` | `false` | Intercept script exit and wait for `DEBUG_TIMEOUT` seconds. |
| `DEBUG_TIMEOUT` | `3600` | Debug exit pause duration in seconds. |
| `VERBOSE` | `false` | Enable Bash command tracing. |

When WDA is not installed on the device, make the IPA available at `WDA_FILE`
(for example, by mounting it into the container). The container also needs
access to the device or to the configured usbmuxd service; the required device
and network mounts depend on the host and deployment environment. The built-in
usbmuxd needs USB access, the iOS 17+ tunnel reads the pair records from
`/var/lib/lockdown`, and the Developer Disk Images are downloaded into
`/opt/zebrunner/devimages/` on demand.

## Exit codes and health

- Exit code `0` means an unrecoverable problem that a restart does not fix: invalid
  configuration, a busy `USBMUXD_PORT`, an unavailable usbmuxd, a Developer Image
  that cannot be mounted, or WDA that cannot be installed or started.
- Exit code `1` asks for a restart: the device is not available, go-ncm or the tunnel
  is not ready, port forwarding is broken, or WDA is not responding.
- The image healthcheck requests `http://${WDA_HOST}:${WDA_PORT}/status` and expects
  HTTP 200.
- Set `DEBUG=true` to keep the container alive for `DEBUG_TIMEOUT` seconds after the
  entrypoint exits, and `LOGGER_LEVEL=DEBUG` or `VERBOSE=true` for more output.

## Development

`make help` lists the targets, `make check` runs all of them as CI does (every step runs, the failed ones fail the target):

| Target | What it does |
| --- | --- |
| `make lint` | `tests/lint.sh`: yamllint, actionlint, hadolint, pymarkdown, `bash -n`, ShellCheck and shfmt (style of `.editorconfig`). The tools are installed into `.venv` from `tests/requirements-lint.txt`; hadolint comes from `brew install hadolint` on macOS. |
| `make test` | The tests of `util/logger.sh`, `util/debug.sh` and `entrypoint.sh`: configuration validation, usbmuxd, device polling, Developer Image, WDA installation, start and port forwarding with their recovery and retry limits, Linux iOS 17+ (go-ncm, tunnel), WDA health checks, the `DEBUG` and `VERBOSE` modes. The tools are stubs (`ios`, `nc`, `socat`, `curl`, ...), so no docker and no iOS device are needed, but bash 4+ is (on macOS `brew install bash`). |
| `make docker` | `tests/image_test.sh`: builds the image (`linux/amd64`, `IMAGE` overrides its tag, `REBUILD=true` rebuilds it), checks its contents, configuration, configuration validation and the entrypoint startup without a device. |

Every test script prints its checks and writes JUnit XML into `JUNIT_DIR` when it is set.

The GitHub Actions workflow `.github/workflows/ci.yml` runs the same `lint`, `test` and `docker` jobs on pushes and pull requests to `develop`, `main` and `master`.

## Support

Feel free to support the development with a
[**donation**](https://www.paypal.com/donate/?hosted_button_id=MNHYYCYHAKUVA)
for the next improvements.

<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="https://github.com/zebrunner/zebrunner/raw/master/docs/img/zebrunner_intro.png"></a>
</p>
