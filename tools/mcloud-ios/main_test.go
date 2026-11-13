package main

import (
	"encoding/binary"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/danielpaulus/go-ios/ios"
)

// fakeUsbmuxd listens on the TCP address of USBMUXD_SOCKET_ADDRESS (as netmuxd forwarded by the connector) and reads
// one request, reply answers it (nil: no answer)
func fakeUsbmuxd(t *testing.T, reply []byte) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	t.Setenv("USBMUXD_SOCKET_ADDRESS", listener.Addr().String())
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var header ios.UsbMuxHeader
		if binary.Read(conn, binary.LittleEndian, &header) != nil {
			return
		}
		if _, err := io.CopyN(io.Discard, conn, int64(header.Length)-16); err != nil {
			return
		}
		if reply == nil {
			// silent: the connection stays open until the end of the test
			time.Sleep(5 * time.Second)
			return
		}
		header.Length = 16 + uint32(len(reply))
		if binary.Write(conn, binary.LittleEndian, header) == nil {
			conn.Write(reply)
		}
	}()
}

func TestAddNetworkDeviceReadsTheReply(t *testing.T) {
	fakeUsbmuxd(t, ios.ToPlistBytes(map[string]interface{}{"MessageType": "Result", "Number": 0}))
	if err := addNetworkDevice("00008030-TEST", "192.0.2.1"); err != nil {
		t.Fatalf("addNetworkDevice: %v", err)
	}
}

func TestAddNetworkDeviceTimesOutOnASilentNetmuxd(t *testing.T) {
	defer func(timeout time.Duration) { muxTimeout = timeout }(muxTimeout)
	muxTimeout = 200 * time.Millisecond
	fakeUsbmuxd(t, nil)
	done := make(chan error, 1)
	go func() { done <- addNetworkDevice("00008030-TEST", "192.0.2.1") }()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "timeout") {
			t.Fatalf("addNetworkDevice: want a timeout error, got %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("addNetworkDevice still waits for the reply of a silent netmuxd")
	}
}
