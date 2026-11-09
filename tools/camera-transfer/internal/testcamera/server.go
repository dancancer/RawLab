// Package testcamera supplies a synthetic TCP responder, never a real camera.
package testcamera

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"testing"
	"unicode/utf16"
)

type Request struct {
	Op     uint16
	ID     uint32
	Params []uint32
}

func String(s string) []byte {
	u := append(utf16.Encode([]rune(s)), 0)
	b := []byte{byte(len(u))}
	for _, v := range u {
		b = binary.LittleEndian.AppendUint16(b, v)
	}
	return b
}

func Device(model, firmware string) []byte {
	b := []byte{100, 0, 17, 0, 0, 0, 100, 0, 0, 0, 0}
	ops := []uint16{0x1001, 0x1002, 0x1003, 0x1004, 0x1007, 0x1008, 0x1009, 0x9201, 0x9202, 0x923b, 0x923c, 0x923d}
	b = append(b, U32(uint32(len(ops)))...)
	for _, op := range ops {
		b = binary.LittleEndian.AppendUint16(b, op)
	}
	b = append(b, make([]byte, 16)...)
	for _, s := range []string{"Sony Corporation", model, firmware, "SYNTHETIC-ONLY"} {
		b = append(b, String(s)...)
	}
	return b
}

func Object(name string, size uint32, format uint16) []byte {
	b := make([]byte, 52)
	binary.LittleEndian.PutUint32(b, 0x10001)
	binary.LittleEndian.PutUint16(b[4:], format)
	binary.LittleEndian.PutUint32(b[8:], size)
	for _, s := range []string{name, "20260101T120000", "20260101T120000", ""} {
		b = append(b, String(s)...)
	}
	return b
}

func Contents(name string, size uint64) []byte {
	b := make([]byte, 144)
	b = append(b, U32(1)...)
	for _, v := range []uint32{1, 9, 100, 1, 0, 0, 1} {
		b = append(b, U32(v)...)
	}
	for i := 0; i < 4; i++ {
		b = append(b, U64(1767268800000)...)
	}
	for _, v := range []uint32{0, 0, 0, 0, 1, 2, uint32(len(name) + 1)} {
		b = append(b, U32(v)...)
	}
	b = append(b, []byte(name)...)
	b = append(b, 0)
	b = append(b, U32(0xb101)...)
	b = append(b, U64(size)...)
	b = append(b, make([]byte, 32+12)...)
	return b
}

type Server struct {
	Address     string
	Listener    net.Listener
	mu          sync.Mutex
	connections []net.Conn
	ops         []uint16
}

func Start(t testing.TB, handler func(net.Conn, Request)) *Server {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Address: l.Addr().String(), Listener: l}
	t.Cleanup(func() {
		l.Close()
		s.mu.Lock()
		defer s.mu.Unlock()
		for _, c := range s.connections {
			c.Close()
		}
	})
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			s.mu.Lock()
			s.connections = append(s.connections, c)
			s.mu.Unlock()
			go s.serve(c, handler)
		}
	}()
	return s
}

func (s *Server) serve(c net.Conn, handler func(net.Conn, Request)) {
	defer c.Close()
	typ, p, err := ReadPacket(c)
	if err != nil {
		return
	}
	if typ == 1 {
		// Connection number, responder GUID, UTF-16 name, PTP/IP version.
		ack := append(U32(7), make([]byte, 16)...)
		ack = append(ack, []byte{'S', 0, 'o', 0, 'n', 0, 'y', 0, 0, 0, 0, 0, 1, 0}...)
		Packet(c, 2, ack)
	} else if typ == 3 && len(p) == 4 && binary.LittleEndian.Uint32(p) == 7 {
		Packet(c, 4, nil)
		io.Copy(io.Discard, c)
		return
	} else {
		return
	}
	for {
		typ, p, err = ReadPacket(c)
		if err != nil {
			return
		}
		if typ != 6 || len(p) < 10 {
			return
		}
		r := Request{Op: binary.LittleEndian.Uint16(p[4:]), ID: binary.LittleEndian.Uint32(p[6:])}
		for i := 10; i+4 <= len(p); i += 4 {
			r.Params = append(r.Params, binary.LittleEndian.Uint32(p[i:]))
		}
		s.mu.Lock()
		s.ops = append(s.ops, r.Op)
		s.mu.Unlock()
		handler(c, r)
	}
}

func (s *Server) Operations() []uint16 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]uint16(nil), s.ops...)
}

func U32(v uint32) []byte { b := make([]byte, 4); binary.LittleEndian.PutUint32(b, v); return b }
func U64(v uint64) []byte { b := make([]byte, 8); binary.LittleEndian.PutUint64(b, v); return b }

func Packet(w io.Writer, typ uint32, p []byte) {
	b := append(U32(uint32(len(p)+8)), U32(typ)...)
	b = append(b, p...)
	// Deliberately split headers and payloads to exercise short socket reads.
	for len(b) > 0 {
		n := min(3, len(b))
		if _, err := w.Write(b[:n]); err != nil {
			return
		}
		b = b[n:]
	}
}

func Response(w io.Writer, r Request, code uint16) {
	p := []byte{byte(code), byte(code >> 8)}
	Packet(w, 7, append(p, U32(r.ID)...))
}
func Data(w io.Writer, r Request, b []byte) {
	Packet(w, 9, append(U32(r.ID), U64(uint64(len(b)))...))
	split := len(b) / 2
	Packet(w, 10, append(U32(r.ID), b[:split]...))
	Packet(w, 12, append(U32(r.ID), b[split:]...))
	Response(w, r, 0x2001)
}

func ReadPacket(r io.Reader) (uint32, []byte, error) {
	h := make([]byte, 8)
	if _, err := io.ReadFull(r, h); err != nil {
		return 0, nil, err
	}
	n := binary.LittleEndian.Uint32(h)
	if n < 8 || n > 16<<20 {
		return 0, nil, fmt.Errorf("invalid test packet %d", n)
	}
	p := make([]byte, int(n)-8)
	_, err := io.ReadFull(r, p)
	return binary.LittleEndian.Uint32(h[4:]), p, err
}
