package ptpip

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

type SSHOptions struct {
	User, Password, Fingerprint string
	Timeout                     time.Duration
}

type Tunnel struct {
	client  *ssh.Client
	timeout time.Duration
}

func ConnectSSH(ctx context.Context, address string, opts SSHOptions) (*Tunnel, error) {
	if opts.User == "" || opts.Password == "" {
		return nil, errors.New("camera SSH user and password are required")
	}
	fingerprint := strings.TrimSpace(opts.Fingerprint)
	decoded, err := base64.RawStdEncoding.DecodeString(strings.TrimPrefix(fingerprint, "SHA256:"))
	if !strings.HasPrefix(fingerprint, "SHA256:") || err != nil || len(decoded) != 32 {
		return nil, errors.New("camera SHA256 SSH fingerprint is required")
	}
	if opts.Timeout <= 0 {
		opts.Timeout = 15 * time.Second
	}
	d := net.Dialer{Timeout: opts.Timeout}
	raw, err := d.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, fmt.Errorf("connect camera SSH: %w", err)
	}
	stop := context.AfterFunc(ctx, func() { raw.Close() })
	defer stop()
	raw.SetDeadline(deadline(ctx, opts.Timeout))
	cfg := &ssh.ClientConfig{
		User: opts.User,
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			if ssh.FingerprintSHA256(key) != fingerprint {
				return errors.New("camera SSH fingerprint mismatch; password was not sent")
			}
			return nil
		},
		Auth: []ssh.AuthMethod{ssh.Password(opts.Password), ssh.KeyboardInteractive(func(_, _ string, questions []string, _ []bool) ([]string, error) {
			// Sony begins keyboard-interactive authentication with an empty challenge.
			if len(questions) == 0 {
				return []string{}, nil
			}
			if len(questions) != 1 {
				return nil, fmt.Errorf("unsupported camera authentication challenge (%d prompts)", len(questions))
			}
			return []string{opts.Password}, nil
		})},
	}
	connection, channels, requests, err := ssh.NewClientConn(raw, address, cfg)
	if err != nil {
		raw.Close()
		return nil, fmt.Errorf("camera SSH authentication failed: %w", err)
	}
	if err = ctx.Err(); err != nil {
		connection.Close()
		return nil, err
	}
	raw.SetDeadline(time.Time{})
	return &Tunnel{client: ssh.NewClient(connection, channels, requests), timeout: opts.Timeout}, nil
}

func (t *Tunnel) Close() error { return t.client.Close() }

func (t *Tunnel) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	if network != "tcp" || port != "15740" {
		return nil, errors.New("camera tunnel permits only localhost:15740")
	}
	ctx, cancel := context.WithTimeout(ctx, t.timeout)
	defer cancel()
	c, err := t.client.DialContext(ctx, "tcp", "localhost:15740")
	if err != nil {
		t.Close()
		return nil, err
	}
	return &deadlineConn{Conn: c}, nil
}

// SSH channels cannot set socket deadlines. A timed-out channel is closed;
// a new camera session is required instead of reusing an ambiguous transaction.
type deadlineConn struct {
	net.Conn
	mu                    sync.Mutex
	readTimer, writeTimer *time.Timer
	closed                bool
}

func (c *deadlineConn) set(timer **time.Timer, when time.Time) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if *timer != nil {
		(*timer).Stop()
		*timer = nil
	}
	if !when.IsZero() && !c.closed {
		*timer = time.AfterFunc(time.Until(when), func() { c.Close() })
	}
	return nil
}
func (c *deadlineConn) SetReadDeadline(t time.Time) error  { return c.set(&c.readTimer, t) }
func (c *deadlineConn) SetWriteDeadline(t time.Time) error { return c.set(&c.writeTimer, t) }
func (c *deadlineConn) SetDeadline(t time.Time) error {
	c.SetReadDeadline(t)
	return c.SetWriteDeadline(t)
}
func (c *deadlineConn) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	if c.readTimer != nil {
		c.readTimer.Stop()
	}
	if c.writeTimer != nil {
		c.writeTimer.Stop()
	}
	c.mu.Unlock()
	return c.Conn.Close()
}
