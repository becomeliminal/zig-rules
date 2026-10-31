// Two cgo libraries in one static binary: go-ethereum's secp256k1 (C compiled
// by cgo) and libopus (a C archive from configure and make, linked through
// hraban/opus). It signs and recovers, and round-trips a frame of Opus.
package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"math"
	"os"

	"github.com/ethereum/go-ethereum/crypto/secp256k1"
	"github.com/hraban/opus"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	key := sha256.Sum256([]byte("zig-rules"))
	msg := sha256.Sum256([]byte("hello"))
	sig, err := secp256k1.Sign(msg[:], key[:])
	if err != nil {
		return fmt.Errorf("sign: %w", err)
	}
	pub, err := secp256k1.RecoverPubkey(msg[:], sig)
	if err != nil {
		return fmt.Errorf("recover: %w", err)
	}
	again, err := secp256k1.RecoverPubkey(msg[:], sig)
	if err != nil || !bytes.Equal(pub, again) || !secp256k1.VerifySignature(pub, msg[:], sig[:64]) {
		return fmt.Errorf("signature does not verify")
	}
	fmt.Println("secp256k1: signed and verified")

	const rate, frame = 48000, 960 // 20 ms at 48 kHz
	pcm := make([]int16, frame)
	for i := range pcm {
		pcm[i] = int16(8000 * math.Sin(2*math.Pi*440*float64(i)/rate))
	}
	enc, err := opus.NewEncoder(rate, 1, opus.AppVoIP)
	if err != nil {
		return fmt.Errorf("opus encoder: %w", err)
	}
	packet := make([]byte, 1000)
	n, err := enc.Encode(pcm, packet)
	if err != nil || n == 0 {
		return fmt.Errorf("opus encode: %d bytes, %v", n, err)
	}
	dec, err := opus.NewDecoder(rate, 1)
	if err != nil {
		return fmt.Errorf("opus decoder: %w", err)
	}
	out := make([]int16, frame)
	samples, err := dec.Decode(packet[:n], out)
	if err != nil {
		return fmt.Errorf("opus decode: %w", err)
	}
	fmt.Printf("opus: %d samples round-tripped\n", samples)
	return nil
}
