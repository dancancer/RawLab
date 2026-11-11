// Command sony-incremental-fixture is a synthetic Sony PTP/IP responder for
// the iOS simulator integration test. It binds only to loopback and never
// talks to a real camera.
package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const listenAddress = "127.0.0.1:15740"

var fixtureID = uint64(time.Now().UnixNano())
var captureMillis = uint64(time.Now().UnixMilli())

type asset struct {
	content uint32
	file    uint32
	name    string
	bytes   []byte
}

type responder struct {
	mu         sync.Mutex
	log        io.Writer
	jpegFailed bool
	nextConn   int
}

var assets = []asset{
	{content: 0x1001, file: 1, name: "DSC10001.ARW", bytes: append([]byte{
		0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
	}, u64(fixtureID)...)},
	{content: 0x1002, file: 2, name: "DSC10001.JPG", bytes: fixtureJPEG()},
}

func fixtureJPEG() []byte {
	img := image.NewRGBA(image.Rect(0, 0, 320, 160))
	for y := 0; y < 160; y++ {
		for x := 0; x < 320; x++ {
			img.SetRGBA(x, y, color.RGBA{uint8(x), uint8(y), uint8(fixtureID >> 12), 255})
		}
	}
	var encoded bytes.Buffer
	if err := jpeg.Encode(&encoded, img, &jpeg.Options{Quality: 94}); err != nil {
		panic(err)
	}
	return encoded.Bytes()
}

func main() {
	logPath := flag.String("log", "", "append request records to this file")
	readyPath := flag.String("ready", "", "write this file after binding the listener")
	flag.Parse()

	var log io.Writer = io.Discard
	var logFile *os.File
	if *logPath != "" {
		var err error
		logFile, err = os.OpenFile(*logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC|os.O_APPEND, 0600)
		if err != nil {
			fail(err)
		}
		defer logFile.Close()
		log = logFile
	}

	listener, err := net.Listen("tcp", listenAddress)
	if err != nil {
		fail(err)
	}
	defer listener.Close()
	if *readyPath != "" {
		if err := os.WriteFile(*readyPath, []byte(listenAddress+"\n"), 0600); err != nil {
			fail(err)
		}
	}

	server := &responder{log: log}
	for {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		server.mu.Lock()
		server.nextConn++
		connectionID := server.nextConn
		server.mu.Unlock()
		go server.serve(connection, connectionID)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func (s *responder) serve(connection net.Conn, connectionID int) {
	defer connection.Close()
	typ, payload, err := readPacket(connection)
	if err != nil {
		return
	}
	switch typ {
	case 1:
		// PTP/IP InitCommandRequest -> InitCommandAck. The app only consumes the
		// connection number, but the remaining fields keep the wire shape real.
		ack := append(u32(7), make([]byte, 16)...)
		ack = append(ack, []byte{'S', 0, 'o', 0, 'n', 0, 'y', 0, 0, 0, 0, 0, 1, 0}...)
		writePacket(connection, 2, ack)
		for {
			typ, payload, err = readPacket(connection)
			if err != nil {
				return
			}
			if typ != 6 || len(payload) < 10 {
				return
			}
			request := requestFrom(payload)
			s.record(connectionID, request)
			if !s.handle(connection, request) {
				return
			}
		}
	case 3:
		if len(payload) != 4 || binary.LittleEndian.Uint32(payload) != 7 {
			return
		}
		writePacket(connection, 4, nil)
		// The camera event channel is intentionally idle in this import-only
		// fixture. Keep it open until the app closes the session.
		_, _ = io.Copy(io.Discard, connection)
	}
}

type request struct {
	op     uint16
	id     uint32
	params []uint32
}

func requestFrom(payload []byte) request {
	result := request{op: binary.LittleEndian.Uint16(payload[4:]), id: binary.LittleEndian.Uint32(payload[6:])}
	for offset := 10; offset+4 <= len(payload); offset += 4 {
		result.params = append(result.params, binary.LittleEndian.Uint32(payload[offset:]))
	}
	return result
}

func (s *responder) record(connectionID int, request request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	params := make([]string, len(request.params))
	for index, value := range request.params {
		params[index] = strconv.FormatUint(uint64(value), 16)
	}
	line := fmt.Sprintf("connection=%d op=0x%04x id=%d params=%s", connectionID, request.op, request.id, strings.Join(params, ":"))
	if request.op == 0x923d && len(request.params) > 1 {
		file := request.params[1] & 0xffff
		name := "unknown"
		for _, candidate := range assets {
			if candidate.file == file {
				name = candidate.name
				break
			}
		}
		line += fmt.Sprintf(" file=%d name=%s", file, name)
	}
	_, _ = fmt.Fprintln(s.log, line)
}

func (s *responder) handle(connection net.Conn, request request) bool {
	switch request.op {
	case 0x1001:
		data(connection, request, deviceInfo())
	case 0x1002:
		response(connection, request, 0x2001)
	case 0x923c:
		data(connection, request, contentsPage())
	case 0x923d:
		if len(request.params) < 2 {
			response(connection, request, 0x2005)
			return true
		}
		file := request.params[1] & 0xffff
		if file == 2 {
			s.mu.Lock()
			failJPEG := !s.jpegFailed
			if failJPEG {
				s.jpegFailed = true
			}
			s.mu.Unlock()
			if failJPEG {
				// Force the first JPEG to fail after the ARW has been saved. The
				// next PTP/IP session receives it normally.
				return false
			}
		}
		var selected *asset
		for index := range assets {
			if assets[index].file == file {
				selected = &assets[index]
				break
			}
		}
		if selected == nil {
			response(connection, request, 0x2009)
			return true
		}
		data(connection, request, selected.bytes)
	default:
		response(connection, request, 0x2005)
	}
	return true
}

func deviceInfo() []byte {
	operations := []uint16{0x1001, 0x1002, 0x1003, 0x1004, 0x1007, 0x1008, 0x1009, 0x923b, 0x923c, 0x923d}
	result := make([]byte, 0, 512)
	appendU16(&result, 100)
	appendU32(&result, 17)
	appendU16(&result, 100)
	appendPTPString(&result, "Sony")
	appendU16(&result, 0)
	appendU32(&result, uint32(len(operations)))
	for _, operation := range operations {
		appendU16(&result, operation)
	}
	for index := 0; index < 4; index++ {
		appendU32(&result, 0)
	}
	for _, value := range []string{"Sony Corporation", "ILCE-6700", "2.00", fmt.Sprintf("SYNTHETIC-%x", fixtureID)} {
		appendPTPString(&result, value)
	}
	return result
}

func contentsPage() []byte {
	result := make([]byte, 144)
	appendU32(&result, uint32(len(assets)))
	for index, candidate := range assets {
		appendU32(&result, uint32(index+1))
		appendU32(&result, candidate.content)
		result = append(result, make([]byte, 20)...)
		for repeat := 0; repeat < 4; repeat++ {
			appendU64(&result, captureMillis)
		}
		result = append(result, make([]byte, 12)...)
		appendU32(&result, 0) // no shot marks
		appendU32(&result, 1) // one still representation
		appendU32(&result, candidate.file)
		path := []byte("A:/DCIM/100MSDCF/" + candidate.name)
		appendU32(&result, uint32(len(path)+1))
		result = append(result, path...)
		result = append(result, 0)
		appendU32(&result, 0xb101)
		appendU64(&result, uint64(len(candidate.bytes)))
		result = append(result, make([]byte, 32)...)
		appendU32(&result, 0) // representation metadata extension
		appendU32(&result, 0) // video=false
		appendU32(&result, 0) // audio=false
	}
	return result
}

func appendPTPString(target *[]byte, value string) {
	utf16 := []uint16{}
	for _, runeValue := range value {
		utf16 = append(utf16, uint16(runeValue))
	}
	*target = append(*target, byte(len(utf16)+1))
	for _, codeUnit := range utf16 {
		appendU16(target, codeUnit)
	}
	appendU16(target, 0)
}

func data(connection net.Conn, request request, payload []byte) {
	start := append(u32(request.id), u64(uint64(len(payload)))...)
	writePacket(connection, 9, start)
	// Deliberately split data into two packets and small writes to exercise the
	// simulator's short-read path as well as PTP/IP's start/data/end sequence.
	middle := len(payload) / 2
	writePacket(connection, 10, append(u32(request.id), payload[:middle]...))
	writePacket(connection, 12, append(u32(request.id), payload[middle:]...))
	response(connection, request, 0x2001)
}

func response(connection net.Conn, request request, code uint16) {
	payload := append(u16(code), u32(request.id)...)
	writePacket(connection, 7, payload)
}

func readPacket(reader io.Reader) (uint32, []byte, error) {
	header := make([]byte, 8)
	if _, err := io.ReadFull(reader, header); err != nil {
		return 0, nil, err
	}
	length := binary.LittleEndian.Uint32(header)
	if length < 8 || length > 16<<20 {
		return 0, nil, fmt.Errorf("invalid PTP/IP packet length %d", length)
	}
	payload := make([]byte, int(length)-8)
	_, err := io.ReadFull(reader, payload)
	return binary.LittleEndian.Uint32(header[4:]), payload, err
}

func writePacket(writer io.Writer, typ uint32, payload []byte) {
	packet := append(u32(uint32(len(payload)+8)), u32(typ)...)
	packet = append(packet, payload...)
	for len(packet) > 0 {
		count := len(packet)
		if count > 3 {
			count = 3
		}
		if _, err := writer.Write(packet[:count]); err != nil {
			return
		}
		packet = packet[count:]
	}
}

func u16(value uint16) []byte {
	result := make([]byte, 2)
	binary.LittleEndian.PutUint16(result, value)
	return result
}

func u32(value uint32) []byte {
	result := make([]byte, 4)
	binary.LittleEndian.PutUint32(result, value)
	return result
}

func u64(value uint64) []byte {
	result := make([]byte, 8)
	binary.LittleEndian.PutUint64(result, value)
	return result
}

func appendU16(target *[]byte, value uint16) { *target = append(*target, u16(value)...) }
func appendU32(target *[]byte, value uint32) { *target = append(*target, u32(value)...) }
func appendU64(target *[]byte, value uint64) { *target = append(*target, u64(value)...) }
