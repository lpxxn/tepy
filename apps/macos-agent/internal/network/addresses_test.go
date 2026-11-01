package network

import (
	"errors"
	"fmt"
	"net"
	"testing"
)

type address string

func (a address) Network() string { return "ip" }
func (a address) String() string  { return string(a) }

func TestCollectFiltersDeduplicatesAndSorts(t *testing.T) {
	interfaces := []net.Interface{
		{Name: "lo0", Flags: net.FlagUp | net.FlagLoopback},
		{Name: "en1"},
		{Name: "en0", Flags: net.FlagUp},
		{Name: "utun2", Flags: net.FlagUp},
	}
	result := collect(interfaces, func(iface net.Interface) ([]net.Addr, error) {
		if iface.Name == "lo0" || iface.Name == "en1" {
			t.Fatal("queried a down or loopback interface")
		}
		if iface.Name == "utun2" {
			return []net.Addr{address("fd00::1/64")}, nil
		}
		return []net.Addr{address("2001:db8::1/64"), address("192.168.50.90/24"),
			address("192.168.50.90/24"), address("::ffff:192.168.50.90/128"),
			address("127.0.0.1/8"), address("::1/128"), address("fe80::1%en0/64"),
			address("169.254.1.2/16"), address("224.0.0.1/4"), address("::/128"),
			address("bad"), nil}, nil
	})
	if !result.Available || len(result.Addresses) != 3 {
		t.Fatal(result)
	}
	if a := result.Addresses[0]; a.IP != "192.168.50.90" || a.Interface != "en0" || a.Family != "ipv4" {
		t.Fatal(a)
	}
	if result.Addresses[1].IP != "2001:db8::1" || result.Addresses[2].Interface != "utun2" {
		t.Fatal(result)
	}
}

func TestCollectFailureAndBound(t *testing.T) {
	result := collect([]net.Interface{{Name: "en0", Flags: net.FlagUp}}, func(net.Interface) ([]net.Addr, error) {
		return nil, errors.New("sample error")
	})
	if result.Available || result.Addresses == nil || len(result.Addresses) != 0 {
		t.Fatal(result)
	}
	result = collect([]net.Interface{{Name: "en0", Flags: net.FlagUp}}, func(net.Interface) ([]net.Addr, error) {
		var values []net.Addr
		for i := 50; i > 0; i-- {
			values = append(values, address(fmt.Sprintf("10.0.0.%d/24", i)))
		}
		return values, nil
	})
	if !result.Available || len(result.Addresses) != MaxAddresses || result.Addresses[0].IP != "10.0.0.1" || result.Addresses[31].IP != "10.0.0.32" {
		t.Fatal(result)
	}
}
