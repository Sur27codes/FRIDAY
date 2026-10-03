package rpcframe

import (
	"bytes"
	"encoding/binary"
	"testing"
)

type sample struct {
	A string
	B int
}

func TestWriteReadFrame_RoundTrip(t *testing.T) {
	var buf bytes.Buffer
	in := sample{A: "hello", B: 42}
	if err := WriteFrame(&buf, in); err != nil {
		t.Fatalf("write: %v", err)
	}
	var out sample
	if err := ReadFrame(&buf, &out); err != nil {
		t.Fatalf("read: %v", err)
	}
	if out != in {
		t.Fatalf("round trip mismatch: got %+v want %+v", out, in)
	}
}

func TestReadFrame_TruncatedLengthPrefixErrors(t *testing.T) {
	buf := bytes.NewBuffer([]byte{0x00, 0x01}) // only 2 of 4 length bytes
	var out sample
	if err := ReadFrame(buf, &out); err == nil {
		t.Fatal("expected error on truncated length prefix")
	}
}

func TestReadFrame_TruncatedPayloadErrors(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteFrame(&buf, sample{A: "x", B: 1}); err != nil {
		t.Fatalf("write: %v", err)
	}
	full := buf.Bytes()
	truncated := bytes.NewReader(full[:len(full)-2]) // chop the payload short
	var out sample
	if err := ReadFrame(truncated, &out); err == nil {
		t.Fatal("expected error on truncated payload")
	}
}

func TestReadFrame_InvalidJSONErrors(t *testing.T) {
	// WriteFrame validates JSON before sending (json.Marshal itself
	// rejects malformed output), so a genuinely invalid-JSON frame must
	// be constructed directly, byte-for-byte, to exercise ReadFrame's
	// decode-error path — simulating a corrupted or malicious peer that
	// doesn't go through this package's own WriteFrame at all.
	var buf bytes.Buffer
	payload := []byte("not valid json{{{")
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(payload)))
	buf.Write(lenBuf[:])
	buf.Write(payload)

	var out sample
	if err := ReadFrame(&buf, &out); err == nil {
		t.Fatal("expected error decoding invalid JSON payload")
	}
}

func TestReadFrame_OversizedClaimedLengthRejected(t *testing.T) {
	var lenBuf [4]byte
	lenBuf[0] = 0xFF // absurdly large claimed length
	lenBuf[1] = 0xFF
	lenBuf[2] = 0xFF
	lenBuf[3] = 0xFF
	buf := bytes.NewReader(lenBuf[:])
	var out sample
	if err := ReadFrame(buf, &out); err == nil {
		t.Fatal("expected rejection of an oversized claimed frame length")
	}
}
