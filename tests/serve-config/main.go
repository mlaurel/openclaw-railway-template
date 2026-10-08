// Checks tailscale/serve.json against Tailscale's own ServeConfig type.
//
// containerboot decodes the file with a lenient json.Unmarshal, so a misspelled
// field is silently ignored. This check decodes strictly against the pinned
// tailscale.com module and asserts the security properties the template relies
// on: raw TCP forwarding only (no HTTP proxy that injects forwarded headers) and
// no Funnel (no public exposure).
//
// Usage: go run . <path-to-serve.json>
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"

	"tailscale.com/ipn"
)

const gatewayAddress = "openclaw.railway.internal:8080"

func main() {
	if err := check(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, "serve.json:", err)
		os.Exit(1)
	}
	fmt.Println("serve.json: ok")
}

func check(path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	// containerboot substitutes this placeholder before decoding.
	raw = bytes.ReplaceAll(raw, []byte("${TS_CERT_DOMAIN}"), []byte("openclaw.example.ts.net"))

	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var config ipn.ServeConfig
	if err := decoder.Decode(&config); err != nil {
		return fmt.Errorf("does not match ipn.ServeConfig: %w", err)
	}

	if len(config.Web) > 0 || len(config.Services) > 0 {
		return fmt.Errorf("must not define Web or Services handlers; HTTP proxying adds forwarded headers the Gateway rejects")
	}
	if len(config.AllowFunnel) > 0 {
		return fmt.Errorf("must not enable Funnel; the Gateway must stay private to the tailnet")
	}

	expected := map[uint16]bool{443: true, 18789: false} // port -> terminates TLS
	if len(config.TCP) != len(expected) {
		return fmt.Errorf("expected exactly ports 443 and 18789, got %d TCP handlers", len(config.TCP))
	}
	for port, terminatesTLS := range expected {
		handler, ok := config.TCP[port]
		if !ok {
			return fmt.Errorf("missing TCP handler for port %d", port)
		}
		if handler.HTTP || handler.HTTPS {
			return fmt.Errorf("port %d must be a raw TCP forward, not an HTTP handler", port)
		}
		if handler.TCPForward != gatewayAddress {
			return fmt.Errorf("port %d forwards to %q, want %q", port, handler.TCPForward, gatewayAddress)
		}
		if handler.ProxyProtocol != 0 {
			return fmt.Errorf("port %d must not send a PROXY protocol header", port)
		}
		if (handler.TerminateTLS != "") != terminatesTLS {
			return fmt.Errorf("port %d TerminateTLS = %q, want TLS termination %v", port, handler.TerminateTLS, terminatesTLS)
		}
	}
	return nil
}
