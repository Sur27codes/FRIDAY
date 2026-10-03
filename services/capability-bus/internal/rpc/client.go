package rpc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"

	"friday/rpcframe"
)

var ErrCapabilityBusUnavailable = errors.New("capability bus unavailable")

type Client struct {
	socketPath string
	timeout    time.Duration
}

func NewClient(socketPath string, timeout time.Duration) *Client {
	if timeout <= 0 {
		timeout = 10 * time.Second // TBD — benchmark required
	}
	return &Client{socketPath: socketPath, timeout: timeout}
}

func (c *Client) call(ctx context.Context, method string, payload interface{}, out interface{}) error {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", c.socketPath)
	if err != nil {
		return fmt.Errorf("%w: dialing capability bus: %v", ErrCapabilityBusUnavailable, err)
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		conn.SetDeadline(deadline)
	}

	b, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshaling request: %w", err)
	}
	if err := rpcframe.WriteFrame(conn, Envelope{Method: method, Payload: b}); err != nil {
		return fmt.Errorf("%w: writing request: %v", ErrCapabilityBusUnavailable, err)
	}

	var respEnv Envelope
	if err := rpcframe.ReadFrame(conn, &respEnv); err != nil {
		return fmt.Errorf("%w: reading response: %v", ErrCapabilityBusUnavailable, err)
	}
	if respEnv.Error != nil {
		return respEnv.Error
	}
	if out != nil {
		if err := unmarshalPayload(respEnv.Payload, out); err != nil {
			return fmt.Errorf("malformed response payload: %w", err)
		}
	}
	return nil
}

// Dispatch is the ONLY production-execution RPC this client exposes —
// there is no RunAnything/ExecuteShell/InvokeRawFunction method (M4
// brief §10).
func (c *Client) Dispatch(ctx context.Context, req DispatchRequest) (DispatchResponse, error) {
	var resp DispatchResponse
	err := c.call(ctx, "Dispatch", req, &resp)
	return resp, err
}

// DevSeedIR and DevSeedTask are Phase-1/M4-only test bootstrap calls —
// see protocol.go's doc comment on DevSeedIRRequest for why these exist
// and why they are not part of the production execution path.
func (c *Client) DevSeedIR(ctx context.Context, req DevSeedIRRequest) error {
	var resp DevSeedResponse
	return c.call(ctx, "DevSeedIR", req, &resp)
}

func (c *Client) DevSeedTask(ctx context.Context, req DevSeedTaskRequest) error {
	var resp DevSeedResponse
	return c.call(ctx, "DevSeedTask", req, &resp)
}
