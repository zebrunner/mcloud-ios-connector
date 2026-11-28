#!/bin/bash
# The peer filter of a connector (README.md#peer-filter): the listeners of the connector (usbmuxd, the go-ios agent and
# its userspace tunnel, the forward and the relays of WebDriverAgent, the ssh relay of a simulator; the adb server of
# mcloud-android-connector) have no authentication, so only the containers of
# CONNECTOR_PEERS (the STF and appium containers of the device, by their names on the docker network of the device) open
# new connections to the connector. A packet filter of the network namespace of the container (iptables, NET_ADMIN)
# drops the new connections of every other host of the docker networks of the container: the docker host itself
# through the gateway of the network, an emulator container joined to the network, the containers of other devices on
# a shared network. The loopback, the answers to the connections of the connector and its other interfaces (the tunnel
# of a device, go-ncm) are not filtered. The names are resolved again every PEER_FILTER_INTERVAL seconds: a recreated peer gets
# its new address; a connection attempt dropped meanwhile is retried by TCP. Without CONNECTOR_PEERS nothing is
# filtered (the behaviour of the earlier versions). Sourced by the entrypoint after util/logger.sh.
# Compatible with the bash of the image (5): associative arrays.

# the chain of the filter
PEER_FILTER_CHAIN="MCLOUD_PEERS"
# the allowed addresses of the peers, ip -> name
declare -A peerFilterAddresses=()

# peerFilterTables <arguments...>: iptables, waiting for the lock of xtables
peerFilterTables() {
  iptables -w 5 "$@"
}

# peerFilterRefresh: the addresses of the peers of now: the new ones are allowed, the ones of no peer any more are not
peerFilterRefresh() {
  local name ip _
  local -A wanted=()
  local -a names
  IFS=',' read -r -a names <<< "$CONNECTOR_PEERS"
  for name in "${names[@]}"; do
    while read -r ip _; do
      [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && wanted[$ip]="$name"
    done < <(getent ahostsv4 "$name" 2> /dev/null)
  done
  for ip in "${!wanted[@]}"; do
    [[ -z "${peerFilterAddresses[$ip]:-}" ]] || continue
    if peerFilterTables -I "$PEER_FILTER_CHAIN" -s "$ip" -j ACCEPT; then
      peerFilterAddresses[$ip]="${wanted[$ip]}"
      logger "Peer filter: ${wanted[$ip]} (${ip}) reaches the connector."
    fi
  done
  for ip in "${!peerFilterAddresses[@]}"; do
    [[ -z "${wanted[$ip]:-}" ]] || continue
    peerFilterTables -D "$PEER_FILTER_CHAIN" -s "$ip" -j ACCEPT 2> /dev/null
    logger "Peer filter: ${peerFilterAddresses[$ip]} (${ip}) is not a peer any more."
    unset "peerFilterAddresses[$ip]"
  done
}

# startPeerFilter: installs the filter of CONNECTOR_PEERS and refreshes it in the background; nothing without it. A
# filter that can not be installed (no NET_ADMIN, no packet filter of the kernel) is a configuration error: the
# entrypoint exits with 0, the connector does not run unfiltered
startPeerFilter() {
  if [[ -z "${CONNECTOR_PEERS:-}" ]]; then
    logger "WARN" "CONNECTOR_PEERS is empty: every host of the docker network of the device (also the docker host) reaches the listeners of the connector (README.md#peer-filter)."
    return 0
  fi
  if [[ ! "$CONNECTOR_PEERS" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*(,[A-Za-z0-9][A-Za-z0-9_.-]*)*$ ]]; then
    logger "ERROR" "CONNECTOR_PEERS must be the names of containers separated by commas, but it is '${CONNECTOR_PEERS}'. Exiting!"
    exit 0
  fi
  if [[ ! "$PEER_FILTER_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    logger "ERROR" "PEER_FILTER_INTERVAL must be a positive integer, but it is '${PEER_FILTER_INTERVAL}'. Exiting!"
    exit 0
  fi
  local output
  # a filter of an earlier start of the container (a restart keeps the network namespace) is replaced
  peerFilterTables -D INPUT -i eth+ -m conntrack --ctstate NEW -j "$PEER_FILTER_CHAIN" > /dev/null 2>&1
  peerFilterTables -F "$PEER_FILTER_CHAIN" > /dev/null 2>&1
  peerFilterTables -X "$PEER_FILTER_CHAIN" > /dev/null 2>&1
  if ! output=$(peerFilterTables -N "$PEER_FILTER_CHAIN" 2>&1 &&
    peerFilterTables -A "$PEER_FILTER_CHAIN" -j DROP 2>&1 &&
    peerFilterTables -I INPUT -i eth+ -m conntrack --ctstate NEW -j "$PEER_FILTER_CHAIN" 2>&1); then
    logger "ERROR" "The peer filter of CONNECTOR_PEERS can not be installed (the container needs --cap-add NET_ADMIN): ${output}"
    logger "ERROR" "The connector does not run without it: CONNECTOR_PEER_FILTER: false of mcloud-agent turns it off (README.md#peer-filter). Exiting!"
    exit 0
  fi
  # IPv6: no peer uses it (docker resolves the names to IPv4), every new connection over it is dropped; a container
  # without IPv6 has nothing to filter
  ip6tables -w 5 -D INPUT -i eth+ -m conntrack --ctstate NEW -j DROP > /dev/null 2>&1
  ip6tables -w 5 -I INPUT -i eth+ -m conntrack --ctstate NEW -j DROP > /dev/null 2>&1
  logger "Peer filter: only ${CONNECTOR_PEERS//,/, } open connections to the connector (README.md#peer-filter)."
  peerFilterRefresh
  # the refresh ends with the entrypoint ($$ is its PID in the subshell too)
  (
    while kill -0 "$$" 2> /dev/null; do
      sleep "$PEER_FILTER_INTERVAL"
      peerFilterRefresh
    done
  ) &
}
