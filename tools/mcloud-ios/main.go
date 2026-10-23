// mcloud-ios: the usbmuxd and lockdown requests of the connector that the go-ios CLI does not have.
//
//	mcloud-ios wifi-connections <udid> [on|off]  shows or sets EnableWifiConnections of the device (lockdown over Wi-Fi)
//	mcloud-ios add-network-device <udid> <ip>     adds a network device to netmuxd (the AddDevice request)
//
// The usbmuxd address is read from USBMUXD_SOCKET_ADDRESS like go-ios does, /var/run/usbmuxd by default.
package main

import (
	"bytes"
	"fmt"
	"os"

	"github.com/danielpaulus/go-ios/ios"
	"howett.net/plist"
)

const (
	wirelessDomain = "com.apple.mobile.wireless_lockdown"
	wifiKey        = "EnableWifiConnections"
)

func main() {
	if len(os.Args) < 3 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "wifi-connections":
		state := ""
		if len(os.Args) > 3 {
			state = os.Args[3]
		}
		err = wifiConnections(os.Args[2], state)
	case "add-network-device":
		if len(os.Args) < 4 {
			usage()
		}
		err = addNetworkDevice(os.Args[2], os.Args[3])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: mcloud-ios wifi-connections <udid> [on|off]")
	fmt.Fprintln(os.Stderr, "       mcloud-ios add-network-device <udid> <ip>")
	os.Exit(2)
}

// wifiConnections prints EnableWifiConnections of the device after setting it to the state, if any
func wifiConnections(udid string, state string) error {
	device, err := ios.GetDevice(udid)
	if err != nil {
		return err
	}
	lockdown, err := ios.ConnectLockdownWithSession(device)
	if err != nil {
		return err
	}
	defer lockdown.Close()
	switch state {
	case "on", "off":
		if err := lockdown.SetValueForDomain(wifiKey, wirelessDomain, state == "on"); err != nil {
			return err
		}
	case "":
	default:
		return fmt.Errorf("the state must be on or off, but it is '%s'", state)
	}
	value, err := lockdown.GetValueForDomain(wifiKey, wirelessDomain)
	if err != nil {
		return err
	}
	fmt.Printf("%s=%v\n", wifiKey, value)
	return nil
}

// addNetworkDevice sends the AddDevice extension of netmuxd: the device is reached over the network at the ip,
// netmuxd finds its pair record by the udid. The reply is printed, the caller checks the device with `ios info`
func addNetworkDevice(udid string, ip string) error {
	mux, err := ios.NewUsbMuxConnectionSimple()
	if err != nil {
		return err
	}
	defer mux.Close()
	request := map[string]interface{}{
		"MessageType":    "AddDevice",
		"ConnectionType": "Network",
		"ServiceName":    "_apple-mobdev2._tcp.local",
		"IPAddress":      ip,
		"DeviceID":       udid,
	}
	if err := mux.Send(request); err != nil {
		return err
	}
	response, err := mux.ReadMessage()
	if err != nil {
		return err
	}
	var result map[string]interface{}
	if _, err := plist.Unmarshal(response.Payload, &result); err != nil {
		return fmt.Errorf("unexpected response: %s", bytes.TrimSpace(response.Payload))
	}
	fmt.Printf("%v\n", result)
	return nil
}
