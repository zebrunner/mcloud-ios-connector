// mcloud-ios: the usbmuxd and lockdown requests of the connector that the go-ios CLI does not have.
//
//	mcloud-ios wifi-connections <udid> [on|off]  shows or sets EnableWifiConnections of the device (lockdown over Wi-Fi)
//	mcloud-ios add-network-device <udid> <ip>     adds a network device to netmuxd (the AddDevice request), fails
//	                                              when netmuxd did not add it
//
// The usbmuxd address is read from USBMUXD_SOCKET_ADDRESS like go-ios does, /var/run/usbmuxd by default.
package main

import (
	"bytes"
	"fmt"
	"os"
	"time"

	"github.com/danielpaulus/go-ios/ios"
	"howett.net/plist"
)

const (
	wirelessDomain = "com.apple.mobile.wireless_lockdown"
	wifiKey        = "EnableWifiConnections"
)

// muxTimeout limits a request to usbmuxd and its reply: a silent netmuxd must not block the entrypoint
var muxTimeout = 10 * time.Second

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
// netmuxd finds its pair record by the udid. The reply is printed; a reply that is not a success is an error
func addNetworkDevice(udid string, ip string) error {
	conn, err := ios.NewDeviceConnection(ios.GetUsbmuxdSocket())
	if err != nil {
		return err
	}
	mux := ios.NewUsbMuxConnection(conn)
	defer mux.Close()
	if err := conn.Conn().SetDeadline(time.Now().Add(muxTimeout)); err != nil {
		return err
	}
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
	return addResult(result, ip)
}

// addResult checks the reply of AddDevice: netmuxd answers {"Result": 1} when it added the device and {"Result": 0}
// when it could not reach the lockdown or the heartbeat of the device at the ip; a usbmuxd reply
// {"MessageType": "Result", "Number": 0} is a success too, another Number is its error code
func addResult(result map[string]interface{}, ip string) error {
	if value, ok := result["Result"]; ok {
		if number, ok := plistInt(value); ok && number == 1 {
			return nil
		}
		return fmt.Errorf("netmuxd did not add the device (Result: %v): it does not answer at %s or refuses its pair record", value, ip)
	}
	if result["MessageType"] == "Result" {
		if number, ok := plistInt(result["Number"]); ok && number == 0 {
			return nil
		}
		return fmt.Errorf("the device is not added (Number: %v)", result["Number"])
	}
	return fmt.Errorf("unexpected reply: %v", result)
}

// plistInt is the integer of a plist value (an unsigned or a signed integer)
func plistInt(value interface{}) (int64, bool) {
	switch number := value.(type) {
	case uint64:
		return int64(number), true
	case int64:
		return number, true
	case int:
		return int64(number), true
	}
	return 0, false
}
