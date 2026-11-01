// Package network samples local interface addresses without DNS or external requests.
package network

import (
	"net"
	"net/netip"
	"sort"
	"strings"

	"github.com/lpxxn/tepy/apps/macos-agent/internal/model"
)

const MaxAddresses = 32

// Sample runs with each normal state sample, so DHCP changes do not require a restart.
// Virtual interfaces are labelled too; the first address is not called a default route.
func Sample() model.Network {
	interfaces, err := net.Interfaces()
	if err != nil {
		return model.Network{Addresses: []model.NetworkAddress{}}
	}
	return collect(interfaces, func(iface net.Interface) ([]net.Addr, error) { return iface.Addrs() })
}

func collect(interfaces []net.Interface, addresses func(net.Interface) ([]net.Addr, error)) model.Network {
	result := model.Network{Available: true, Addresses: []model.NetworkAddress{}}
	seen := map[string]bool{}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || !validName(iface.Name) {
			continue
		}
		values, err := addresses(iface)
		if err != nil {
			// Keep useful addresses from other interfaces while reporting an incomplete sample.
			result.Available = false
			continue
		}
		for _, value := range values {
			if value == nil {
				continue
			}
			host, _, _ := strings.Cut(value.String(), "/")
			ip, err := netip.ParseAddr(host)
			if err != nil {
				continue
			}
			ip = ip.Unmap()
			// RFC1918 / IPv6 ULA are useful; loopback, multicast and link-local are not.
			if !ip.IsGlobalUnicast() || ip.IsLinkLocalUnicast() || ip.Zone() != "" {
				continue
			}
			key := iface.Name + "|" + ip.String()
			if seen[key] {
				continue
			}
			seen[key] = true
			family := "ipv6"
			if ip.Is4() {
				family = "ipv4"
			}
			result.Addresses = append(result.Addresses, model.NetworkAddress{Interface: iface.Name, IP: ip.String(), Family: family})
		}
	}
	// Stable ordering avoids page movement when the OS enumerates interfaces differently.
	sort.Slice(result.Addresses, func(i, j int) bool {
		a, b := result.Addresses[i], result.Addresses[j]
		if a.Family != b.Family {
			return a.Family < b.Family // IPv4 first.
		}
		if a.Interface != b.Interface {
			return a.Interface < b.Interface
		}
		return netip.MustParseAddr(a.IP).Compare(netip.MustParseAddr(b.IP)) < 0
	})
	if len(result.Addresses) > MaxAddresses {
		result.Addresses = result.Addresses[:MaxAddresses]
	}
	return result
}

func validName(name string) bool {
	if name == "" || len(name) > 64 {
		return false
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("_.:-", c)) {
			return false
		}
	}
	return true
}
