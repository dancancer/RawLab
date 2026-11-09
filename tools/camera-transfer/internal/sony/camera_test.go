package sony

import (
	"bytes"
	"context"
	"net"
	"reflect"
	"testing"
	"time"

	"github.com/dancancer/RawLab/tools/camera-transfer/internal/ptpip"
	"github.com/dancancer/RawLab/tools/camera-transfer/internal/testcamera"
)

func connectTest(t *testing.T, s *testcamera.Server, profile Profile) (*Camera, error) {
	t.Helper()
	c, err := ptpip.Dial(context.Background(), s.Address, ptpip.Options{Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return Connect(context.Background(), c, profile, "ILCE-6700", "2.00")
}

func TestStandardListsAndDownloadsExistingObject(t *testing.T) {
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) {
		switch r.Op {
		case 0x1001:
			testcamera.Data(c, r, testcamera.Device("ILCE-6700", "2.00"))
		case 0x1002, 0x1003:
			testcamera.Response(c, r, 0x2001)
		case 0x1004:
			testcamera.Data(c, r, append(testcamera.U32(1), testcamera.U32(0x10001)...))
		case 0x1007:
			testcamera.Data(c, r, append(testcamera.U32(1), testcamera.U32(42)...))
		case 0x1008:
			testcamera.Data(c, r, testcamera.Object("DSC00001.ARW", 8, 0xb101))
		case 0x1009:
			testcamera.Data(c, r, []byte{'I', 'I', 42, 0, 8, 0, 0, 0})
		default:
			testcamera.Response(c, r, 0x2005)
		}
	})
	cam, err := connectTest(t, s, Standard)
	if err != nil {
		t.Fatal(err)
	}
	assets, err := cam.List(context.Background(), 0, 10)
	if err != nil || len(assets) != 1 {
		t.Fatalf("assets=%+v %v", assets, err)
	}
	a := assets[0]
	if a.Name != "DSC00001.ARW" || a.Size != 8 || a.Kind != "arw" {
		t.Fatalf("%+v", a)
	}
	var out bytes.Buffer
	if err = cam.Download(context.Background(), a, &out, 1024); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out.Bytes(), []byte{'I', 'I', 42, 0, 8, 0, 0, 0}) {
		t.Fatal("changed bytes")
	}
	for _, op := range s.Operations() {
		if op >= 0x9000 {
			t.Fatalf("standard mode sent vendor command %x", op)
		}
	}
}

func TestModernContentsUsesReadOnlyCommandProfile(t *testing.T) {
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) {
		switch r.Op {
		case 0x1001:
			testcamera.Data(c, r, testcamera.Device("ILCE-6700", "2.00"))
		case 0x1002, 0x9201:
			testcamera.Response(c, r, 0x2001)
		case 0x9202:
			testcamera.Data(c, r, []byte{44, 1, 1, 0, 0, 0, 1, 210, 0, 0, 0, 0})
		case 0x923b:
			testcamera.Data(c, r, append(testcamera.U32(1), testcamera.U64(1767268800000)...))
		case 0x923c:
			testcamera.Data(c, r, testcamera.Contents("A:/DCIM/100MSDCF/DSC00001.ARW", 8))
		case 0x923d:
			if !reflect.DeepEqual(r.Params, []uint32{9, 0x01000002, 0, 0, 0x80000008}) {
				t.Errorf("wrong read: %v", r.Params)
			}
			testcamera.Data(c, r, []byte{'I', 'I', 42, 0, 8, 0, 0, 0})
		default:
			t.Errorf("unexpected operation %x", r.Op)
			testcamera.Response(c, r, 0x2005)
		}
	})
	cam, err := connectTest(t, s, SonyContents)
	if err != nil {
		t.Fatal(err)
	}
	assets, err := cam.List(context.Background(), 1, 10)
	if err != nil || len(assets) != 1 {
		t.Fatalf("%+v %v", assets, err)
	}
	var out bytes.Buffer
	if err = cam.Download(context.Background(), assets[0], &out, 1024); err != nil {
		t.Fatal(err)
	}
	if out.Len() != 8 {
		t.Fatal(out.Len())
	}
	for _, op := range s.Operations() {
		if op == 0x9212 || op == 0x9205 || op == 0x9207 || op == 0x9250 {
			t.Fatalf("mutation command %x", op)
		}
	}
}

func TestMismatchStopsBeforeSonyHandshake(t *testing.T) {
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) { testcamera.Data(c, r, testcamera.Device("ILCE-7M4", "9.99")) })
	_, err := connectTest(t, s, SonyContents)
	if err == nil {
		t.Fatal("accepted wrong camera")
	}
	if !reflect.DeepEqual(s.Operations(), []uint16{0x1001}) {
		t.Fatal(s.Operations())
	}
}

func TestDecodeRejectsTruncatedAndOversizedDatasets(t *testing.T) {
	if _, err := decodeDevice([]byte{1, 2}); err == nil {
		t.Fatal("short device accepted")
	}
	b := testcamera.Device("ILCE-6700", "2.00")
	b[11], b[12], b[13], b[14] = 255, 255, 255, 255
	if _, err := decodeDevice(b); err == nil {
		t.Fatal("oversized array accepted")
	}
	if _, err := decodeContents(testcamera.Contents("a.arw", 8)[:160], 1); err == nil {
		t.Fatal("truncated contents accepted")
	}
}

func TestContentsRejectsChangedObjectBeforePublication(t *testing.T) {
	lists := 0
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) {
		switch r.Op {
		case 0x1001:
			testcamera.Data(c, r, testcamera.Device("ILCE-6700", "2.00"))
		case 0x1002, 0x9201:
			testcamera.Response(c, r, 0x2001)
		case 0x9202:
			testcamera.Data(c, r, []byte{1})
		case 0x923b:
			testcamera.Data(c, r, append(testcamera.U32(1), testcamera.U64(1767268800000)...))
		case 0x923c:
			lists++
			name := "DSC00001.ARW"
			if lists > 1 {
				name = "DSC00002.ARW"
			}
			testcamera.Data(c, r, testcamera.Contents(name, 8))
		case 0x923d:
			testcamera.Data(c, r, []byte{'I', 'I', 42, 0, 8, 0, 0, 0})
		default:
			testcamera.Response(c, r, 0x2005)
		}
	})
	cam, err := connectTest(t, s, SonyContents)
	if err != nil {
		t.Fatal(err)
	}
	assets, err := cam.List(context.Background(), 1, 10)
	if err != nil {
		t.Fatal(err)
	}
	if err = cam.Download(context.Background(), assets[0], &bytes.Buffer{}, 1024); err == nil {
		t.Fatal("accepted changed camera content under old source metadata")
	}
}
