package rpc

import (
	"encoding/json"
	"net"

	"friday/rpcframe"
)

func unmarshalPayload(raw json.RawMessage, v interface{}) error {
	if len(raw) == 0 {
		return &RPCError{Code: ErrExecutionEnvelopeInvalid, Message: "empty payload"}
	}
	return json.Unmarshal(raw, v)
}

func writeResult(conn net.Conn, method string, payload interface{}) {
	b, err := json.Marshal(payload)
	if err != nil {
		_ = rpcframe.WriteFrame(conn, Envelope{Method: method, Error: &RPCError{
			Code: ErrExecutionEnvelopeInvalid, Message: "server failed to marshal response",
		}})
		return
	}
	_ = rpcframe.WriteFrame(conn, Envelope{Method: method, Payload: b})
}

func writeError(conn net.Conn, method string, code ErrorCode, msg string) {
	_ = rpcframe.WriteFrame(conn, Envelope{Method: method, Error: &RPCError{Code: code, Message: msg}})
}
