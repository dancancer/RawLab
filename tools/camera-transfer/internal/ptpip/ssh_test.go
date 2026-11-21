package ptpip

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func sshServer(t *testing.T, interactive ...bool) (string, string, *atomic.Int32) {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		t.Fatal(err)
	}
	calls := &atomic.Int32{}
	cfg := &ssh.ServerConfig{PasswordCallback: func(_ ssh.ConnMetadata, password []byte) (*ssh.Permissions, error) { calls.Add(1); return nil, nil }}
	cfg.AddHostKey(signer)
	if len(interactive) > 0 && interactive[0] {
		cfg.PasswordCallback = nil
		cfg.KeyboardInteractiveCallback = func(_ ssh.ConnMetadata, challenge ssh.KeyboardInteractiveChallenge) (*ssh.Permissions, error) {
			calls.Add(1)
			if _, err := challenge("camera", "", nil, nil); err != nil {
				return nil, err
			}
			answers, err := challenge("camera", "", []string{"Password:"}, []bool{false})
			if err != nil {
				return nil, err
			}
			if len(answers) != 1 || answers[0] != "test-only" {
				return nil, io.ErrUnexpectedEOF
			}
			return nil, nil
		}
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		connection, channels, requests, err := ssh.NewServerConn(c, cfg)
		if err != nil {
			return
		}
		defer connection.Close()
		go ssh.DiscardRequests(requests)
		for ch := range channels {
			if ch.ChannelType() != "direct-tcpip" {
				ch.Reject(ssh.UnknownChannelType, "test")
				continue
			}
			var payload struct {
				Host       string
				Port       uint32
				Origin     string
				OriginPort uint32
			}
			if ssh.Unmarshal(ch.ExtraData(), &payload) != nil || payload.Host != "localhost" || payload.Port != 15740 {
				ch.Reject(ssh.Prohibited, "wrong destination")
				continue
			}
			if len(interactive) > 1 && interactive[1] {
				connection.Wait()
				return
			}
			c, req, err := ch.Accept()
			if err != nil {
				return
			}
			go ssh.DiscardRequests(req)
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	return l.Addr().String(), ssh.FingerprintSHA256(signer.PublicKey()), calls
}

func TestSSHAcceptsCameraEmptyChallengeBeforePassword(t *testing.T) {
	addr, fingerprint, _ := sshServer(t, true)
	tunnel, err := ConnectSSH(context.Background(), addr, SSHOptions{User: "camera", Password: "test-only", Fingerprint: fingerprint, Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	tunnel.Close()
}

func TestSSHPinsHostBeforeSendingPassword(t *testing.T) {
	addr, _, calls := sshServer(t)
	_, err := ConnectSSH(context.Background(), addr, SSHOptions{User: "camera", Password: "never-log-this", Fingerprint: "SHA256:" + strings.Repeat("A", 43), Timeout: time.Second})
	if err == nil {
		t.Fatal("accepted unknown host key")
	}
	if calls.Load() != 0 {
		t.Fatal("sent password before validating host")
	}
	if strings.Contains(err.Error(), "never-log-this") {
		t.Fatal("password in error")
	}
}

func TestSSHTunnelUsesLocalhostAndHonorsReadDeadline(t *testing.T) {
	addr, fingerprint, _ := sshServer(t)
	tunnel, err := ConnectSSH(context.Background(), addr, SSHOptions{User: "camera", Password: "test-only", Fingerprint: fingerprint, Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	c, err := tunnel.DialContext(context.Background(), "tcp", "ignored:15740")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(time.Second))
	if _, err = c.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 4)
	if _, err = io.ReadFull(c, b); err != nil || string(b) != "ping" {
		t.Fatalf("%q %v", b, err)
	}
	c.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
	if _, err = c.Read(b); err == nil {
		t.Fatal("SSH read ignored deadline")
	}
}

func TestSSHTunnelOpenUsesConfiguredTimeout(t *testing.T) {
	addr, fingerprint, _ := sshServer(t, false, true)
	tunnel, err := ConnectSSH(context.Background(), addr, SSHOptions{User: "camera", Password: "test-only", Fingerprint: fingerprint, Timeout: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	defer tunnel.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err = tunnel.DialContext(ctx, "tcp", "ignored:15740")
	if err == nil || time.Since(start) > 400*time.Millisecond {
		t.Fatalf("forwarding request did not use configured timeout: %v", err)
	}
}
