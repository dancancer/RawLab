// Package ptpip implements the read-only PTP/IP transport used by the Sony probe.
package ptpip

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"sync"
	"time"
	"unicode/utf16"
)

type Options struct {
	GUID        [16]byte
	Timeout     time.Duration
	DialContext func(context.Context, string, string) (net.Conn, error)
}

type ResponseError struct{ Operation, Code uint16 }

func (e *ResponseError) Error() string {
	return fmt.Sprintf("PTP operation 0x%04x failed: 0x%04x", e.Operation, e.Code)
}

type Client struct {
	command, event net.Conn
	timeout        time.Duration
	mu             sync.Mutex
	tx             uint32
	once           sync.Once
	done           chan struct{}
}

func Dial(ctx context.Context, address string, opts Options) (client *Client, err error) {
	if opts.Timeout <= 0 {
		opts.Timeout = 15 * time.Second
	}
	if opts.GUID == ([16]byte{}) {
		if _, err = rand.Read(opts.GUID[:]); err != nil {
			return nil, err
		}
	}
	dial := opts.DialContext
	if dial == nil {
		d := net.Dialer{Timeout: opts.Timeout}
		dial = d.DialContext
	}
	command, err := dial(ctx, "tcp", address)
	if err != nil {
		return nil, fmt.Errorf("connect camera: %w", err)
	}
	c := &Client{command: command, timeout: opts.Timeout, done: make(chan struct{})}
	// During handshake only the command channel exists; cancellation still closes it.
	stop := context.AfterFunc(ctx, func() { command.Close() })
	defer stop()
	defer func() {
		if err != nil {
			c.Close()
		}
	}()
	command.SetDeadline(deadline(ctx, opts.Timeout))
	p := append([]byte(nil), opts.GUID[:]...)
	for _, u := range utf16.Encode([]rune("RawLab camera probe")) {
		p = binary.LittleEndian.AppendUint16(p, u)
	}
	p = binary.LittleEndian.AppendUint16(p, 0)
	p = binary.LittleEndian.AppendUint32(p, 0x00010000)
	if err = writePacket(command, 1, p); err != nil {
		return nil, err
	}
	typ, p, err := readSmall(command, 4096)
	if err != nil {
		return nil, err
	}
	if typ == 5 {
		return nil, errors.New("camera refused PTP/IP connection; check pairing and selected mode")
	}
	if typ != 2 || len(p) < 24 {
		return nil, errors.New("invalid PTP/IP command acknowledgement")
	}
	connection := binary.LittleEndian.Uint32(p)
	event, err := dial(ctx, "tcp", address)
	if err != nil {
		return nil, err
	}
	c.event = event
	stopEvent := context.AfterFunc(ctx, func() { event.Close() })
	defer stopEvent()
	event.SetDeadline(deadline(ctx, opts.Timeout))
	if err = writePacket(event, 3, binary.LittleEndian.AppendUint32(nil, connection)); err != nil {
		return nil, err
	}
	typ, p, err = readSmall(event, 4096)
	if err != nil {
		return nil, err
	}
	if typ != 4 || len(p) != 0 {
		return nil, errors.New("invalid PTP/IP event acknowledgement")
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	command.SetDeadline(time.Time{})
	event.SetDeadline(time.Time{})
	go c.events()
	return c, nil
}

func deadline(ctx context.Context, timeout time.Duration) time.Time {
	t := time.Now().Add(timeout)
	if d, ok := ctx.Deadline(); ok && d.Before(t) {
		return d
	}
	return t
}

func (c *Client) Close() error {
	c.once.Do(func() {
		close(c.done)
		c.command.Close()
		if c.event != nil {
			c.event.Close()
		}
	})
	return nil
}

func (c *Client) events() {
	defer c.Close()
	for {
		typ, p, err := readSmall(c.event, 4096)
		if err != nil {
			return
		}
		switch typ {
		case 8:
			if len(p) < 6 || (len(p)-6)%4 != 0 {
				return
			}
		case 13:
			if len(p) != 0 {
				return
			}
			c.event.SetWriteDeadline(time.Now().Add(c.timeout))
			if writePacket(c.event, 14, nil) != nil {
				return
			}
			c.event.SetWriteDeadline(time.Time{})
		default:
			return
		}
	}
}

// Do executes exactly one operation. A non-nil writer requires a complete data phase.
// The caller owns the allowlist of commands; any failure makes this session unusable.
func (c *Client) Do(ctx context.Context, op uint16, params []uint32, dst io.Writer, limit int64) (received int64, err error) {
	return c.do(ctx, op, params, dst, limit, dst != nil)
}

// DoOptionalData is for session commands whose firmware-dependent acknowledgement
// may contain metadata. Any data phase that does start must still finish correctly.
func (c *Client) DoOptionalData(ctx context.Context, op uint16, params []uint32, dst io.Writer, limit int64) (int64, error) {
	if dst == nil {
		return 0, errors.New("optional metadata needs a bounded receiver")
	}
	return c.do(ctx, op, params, dst, limit, false)
}

func (c *Client) do(ctx context.Context, op uint16, params []uint32, dst io.Writer, limit int64, requireData bool) (received int64, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	select {
	case <-c.done:
		return 0, errors.New("PTP/IP session is closed")
	default:
	}
	if err = ctx.Err(); err != nil {
		return 0, err
	}
	if len(params) > 5 || limit < 0 {
		return 0, errors.New("invalid PTP operation arguments")
	}
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	defer func() {
		if ctx.Err() != nil {
			err = ctx.Err()
		}
		if err != nil {
			c.Close()
			err = fmt.Errorf("PTP operation 0x%04x: %w", op, err)
		} else {
			c.command.SetDeadline(time.Time{})
		}
	}()
	if op == 0x1002 {
		c.tx = 0
	} else {
		c.tx++
	}
	tid := c.tx
	p := binary.LittleEndian.AppendUint32(nil, 1)
	p = binary.LittleEndian.AppendUint16(p, op)
	p = binary.LittleEndian.AppendUint32(p, tid)
	for _, v := range params {
		p = binary.LittleEndian.AppendUint32(p, v)
	}
	c.command.SetWriteDeadline(deadline(ctx, c.timeout))
	if err = writePacket(c.command, 6, p); err != nil {
		return received, err
	}
	c.command.SetWriteDeadline(time.Time{})
	started, ended := false, false
	var expected uint64
	for {
		c.command.SetReadDeadline(deadline(ctx, c.timeout))
		var typ uint32
		var length uint32
		typ, length, err = readHeader(c.command)
		if err != nil {
			return received, err
		}
		if typ == 10 || typ == 12 {
			if !started || ended || dst == nil || length < 4 {
				return received, errors.New("unexpected PTP data packet")
			}
			var id [4]byte
			if _, err = io.ReadFull(c.command, id[:]); err != nil {
				return received, err
			}
			if binary.LittleEndian.Uint32(id[:]) != tid {
				return received, errors.New("PTP data transaction mismatch")
			}
			n := int64(length - 4)
			if n > limit-received || (expected != math.MaxUint64 && uint64(received+n) > expected) {
				return received, errors.New("PTP data exceeds declared length or byte limit")
			}
			// Copy in bounded chunks, independently of the camera's packet/file size.
			var copied int64
			copied, err = io.CopyBuffer(dst, io.LimitReader(c.command, n), make([]byte, 64<<10))
			received += copied
			if err != nil {
				return received, err
			}
			if copied != n {
				return received, io.ErrUnexpectedEOF
			}
			if typ == 12 {
				ended = true
				if expected != math.MaxUint64 && uint64(received) != expected {
					return received, errors.New("PTP data length mismatch")
				}
			}
			continue
		}
		if length > 4096 {
			return received, errors.New("PTP control packet exceeds limit")
		}
		p = make([]byte, length)
		if _, err = io.ReadFull(c.command, p); err != nil {
			return received, err
		}
		switch typ {
		case 9:
			if dst == nil || started || len(p) != 12 {
				return received, fmt.Errorf("unexpected PTP start data (payload=%d, receiver=%t, started=%t)", len(p), dst != nil, started)
			}
			if binary.LittleEndian.Uint32(p) != tid {
				return received, errors.New("PTP start transaction mismatch")
			}
			expected = binary.LittleEndian.Uint64(p[4:])
			if expected != math.MaxUint64 && expected > uint64(limit) {
				return received, errors.New("PTP data exceeds byte limit")
			}
			started = true
		case 7:
			if len(p) < 6 || len(p) > 26 || (len(p)-6)%4 != 0 {
				return received, errors.New("invalid PTP response")
			}
			if binary.LittleEndian.Uint32(p[2:]) != tid {
				return received, errors.New("PTP response transaction mismatch")
			}
			if code := binary.LittleEndian.Uint16(p); code != 0x2001 {
				return received, &ResponseError{op, code}
			}
			if (requireData && !started) || (started && !ended) {
				return received, errors.New("PTP response arrived before complete data")
			}
			return received, nil
		case 13:
			if len(p) != 0 {
				return received, errors.New("invalid PTP probe")
			}
			c.command.SetWriteDeadline(deadline(ctx, c.timeout))
			if err = writePacket(c.command, 14, nil); err != nil {
				return received, err
			}
			c.command.SetWriteDeadline(time.Time{})
		case 11:
			return received, errors.New("camera cancelled PTP transfer")
		default:
			return received, fmt.Errorf("unexpected PTP packet type %d", typ)
		}
	}
}

func readHeader(r io.Reader) (uint32, uint32, error) {
	var h [8]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return 0, 0, err
	}
	n := binary.LittleEndian.Uint32(h[:])
	if n < 8 {
		return 0, 0, errors.New("invalid PTP packet length")
	}
	return binary.LittleEndian.Uint32(h[4:]), n - 8, nil
}

func readSmall(r io.Reader, limit uint32) (uint32, []byte, error) {
	typ, n, err := readHeader(r)
	if err != nil {
		return 0, nil, err
	}
	if n > limit {
		return 0, nil, errors.New("PTP handshake/event packet exceeds limit")
	}
	b := make([]byte, n)
	_, err = io.ReadFull(r, b)
	return typ, b, err
}

func writePacket(w io.Writer, typ uint32, p []byte) error {
	h := binary.LittleEndian.AppendUint32(nil, uint32(len(p)+8))
	h = binary.LittleEndian.AppendUint32(h, typ)
	for _, b := range [][]byte{h, p} {
		for len(b) > 0 {
			n, err := w.Write(b)
			if err != nil {
				return err
			}
			if n == 0 {
				return io.ErrShortWrite
			}
			b = b[n:]
		}
	}
	return nil
}
