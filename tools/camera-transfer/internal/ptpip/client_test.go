package ptpip

import (
	"bytes"
	"context"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/dancancer/RawLab/tools/camera-transfer/internal/testcamera"
)

func TestTransactionStreamsSplitPackets(t *testing.T) {
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) { testcamera.Data(c, r, []byte("original bytes")) })
	c, err := Dial(context.Background(), s.Address, Options{GUID: [16]byte{1}, Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var out bytes.Buffer
	n, err := c.Do(context.Background(), 0x1009, []uint32{42}, &out, 1024)
	if err != nil || n != 14 || out.String() != "original bytes" {
		t.Fatalf("got %d %q %v", n, out.String(), err)
	}
}

func TestTransactionRejectsIncompleteOrMismatchedData(t *testing.T) {
	for _, kind := range []string{"wrong-data-id", "wrong-response-id", "missing-end", "short-length", "over-limit", "data-before-start", "error-after-data", "short-frame"} {
		t.Run(kind, func(t *testing.T) {
			s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) {
				if kind == "short-frame" {
					c.Write([]byte{7, 0, 0, 0, 9, 0, 0, 0})
					return
				}
				if kind != "data-before-start" {
					size := uint64(4)
					if kind == "short-length" {
						size = 5
					}
					if kind == "over-limit" {
						size = 9999
					}
					testcamera.Packet(c, 9, append(testcamera.U32(r.ID), testcamera.U64(size)...))
				}
				id := r.ID
				if kind == "wrong-data-id" {
					id++
				}
				typ := uint32(12)
				if kind == "missing-end" {
					typ = 10
				}
				testcamera.Packet(c, typ, append(testcamera.U32(id), []byte("data")...))
				if kind == "wrong-response-id" {
					r.ID++
				}
				code := uint16(0x2001)
				if kind == "error-after-data" {
					code = 0x2019
				}
				testcamera.Response(c, r, code)
			})
			c, err := Dial(context.Background(), s.Address, Options{Timeout: time.Second})
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			var out bytes.Buffer
			_, err = c.Do(context.Background(), 0x1009, []uint32{42}, &out, 8)
			if err == nil {
				t.Fatalf("accepted %s (%q)", kind, out.String())
			}
		})
	}
}

func TestCancelledTransactionClosesConnection(t *testing.T) {
	started := make(chan struct{})
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) { close(started); var b [1]byte; c.Read(b[:]) })
	c, err := Dial(context.Background(), s.Address, Options{Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { <-started; cancel() }()
	_, err = c.Do(ctx, 0x1009, nil, &bytes.Buffer{}, 1024)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
	_, err = c.Do(context.Background(), 0x1001, nil, &bytes.Buffer{}, 1024)
	if err == nil {
		t.Fatal("reused cancelled session")
	}
}

func TestNoDataOperationRejectsUnexpectedPayload(t *testing.T) {
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) { testcamera.Data(c, r, []byte("unexpected")) })
	c, err := Dial(context.Background(), s.Address, Options{Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, err = c.Do(context.Background(), 0x1002, []uint32{1}, nil, 0)
	if err == nil || !strings.Contains(err.Error(), "data") {
		t.Fatalf("got %v", err)
	}
}

func TestActiveDownloadOutlivesRequestWriteDeadline(t *testing.T) {
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) {
		testcamera.Packet(c, 9, append(testcamera.U32(r.ID), testcamera.U64(6)...))
		for i := 0; i < 6; i++ {
			time.Sleep(40 * time.Millisecond)
			typ := uint32(10)
			if i == 5 {
				typ = 12
			}
			testcamera.Packet(c, typ, append(testcamera.U32(r.ID), byte('a'+i)))
		}
		testcamera.Response(c, r, 0x2001)
	})
	c, err := Dial(context.Background(), s.Address, Options{Timeout: 150 * time.Millisecond,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			raw, err := (&net.Dialer{}).DialContext(ctx, network, address)
			if err != nil {
				return nil, err
			}
			return &deadlineConn{Conn: raw}, nil
		}})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var out bytes.Buffer
	if _, err = c.Do(context.Background(), 0x1009, nil, &out, 6); err != nil || out.String() != "abcdef" {
		t.Fatalf("active download interrupted: %q %v", out.String(), err)
	}
}
