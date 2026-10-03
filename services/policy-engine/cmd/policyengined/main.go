// Command policyengined is the Phase-1 Policy Engine as a real, standalone
// OS process (ADR-021). It is the ONLY process in the system that ever
// holds the Ed25519 private signing key — generated fresh at startup
// (Phase-1 has no persistent key storage across restarts yet; this is a
// disclosed limitation, not a security gap, since a fresh key per
// process lifetime simply means tokens don't outlive a restart, which is
// acceptable for Phase-1's low-stakes capability set). Its public key is
// written to -pubkey-out for the Capability Bus process to read at its
// own startup (ST §S.2.1's key-distribution note).
package main

import (
	"encoding/base64"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"friday/policy-engine/internal/policy"
	"friday/policy-engine/internal/rpc"
)

func main() {
	socketPath := flag.String("socket", "", "path for the Unix domain socket to listen on (required)")
	pubkeyOut := flag.String("pubkey-out", "", "path to write the base64-encoded Ed25519 public key (required)")
	flag.Parse()

	if *socketPath == "" || *pubkeyOut == "" {
		log.Fatal("policyengined: -socket and -pubkey-out are required")
	}

	signer, _, err := policy.NewKeyPair()
	if err != nil {
		log.Fatalf("policyengined: generating key pair: %v", err)
	}

	pubBytes := signer.Public().PublicKeyBytes()
	if err := os.WriteFile(*pubkeyOut, []byte(base64.StdEncoding.EncodeToString(pubBytes)), 0o644); err != nil {
		log.Fatalf("policyengined: writing public key file: %v", err)
	}

	engine := policy.NewEngine(signer)
	srv, err := rpc.Listen(*socketPath, engine)
	if err != nil {
		log.Fatalf("policyengined: listen on %s: %v", *socketPath, err)
	}
	log.Printf("policyengined: listening on %s, public key written to %s", *socketPath, *pubkeyOut)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Print("policyengined: shutting down")
		srv.Close()
	}()

	if err := srv.Serve(); err != nil {
		log.Printf("policyengined: serve exited: %v", err)
	}
}
