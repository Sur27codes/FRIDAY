package rpcapi

import (
	"bytes"
	"encoding/json"
	"io"
	"net"

	"friday/rpcframe"
)

func bytesReader(raw json.RawMessage) io.Reader {
	if len(raw) == 0 {
		return bytes.NewReader([]byte("{}"))
	}
	return bytes.NewReader(raw)
}

func writeResult(conn net.Conn, method string, payload interface{}) {
	b, err := json.Marshal(payload)
	if err != nil {
		_ = rpcframe.WriteFrame(conn, Envelope{Method: method, Error: &RPCError{
			Code: ErrInternalSafeError, Message: "server failed to marshal response",
		}})
		return
	}
	_ = rpcframe.WriteFrame(conn, Envelope{Method: method, Payload: b})
}

func writeError(conn net.Conn, method string, code ErrorCode, msg string) {
	_ = rpcframe.WriteFrame(conn, Envelope{Method: method, Error: &RPCError{Code: code, Message: msg}})
}
