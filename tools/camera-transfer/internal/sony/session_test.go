package sony

import (
	"net"
	"testing"

	"github.com/dancancer/RawLab/tools/camera-transfer/internal/testcamera"
)

func TestSonySessionAcceptsBoundedConnectionResponseData(t *testing.T) {
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) {
		switch r.Op {
		case 0x1001:
			testcamera.Data(c, r, testcamera.Device("ILCE-6700", "2.00"))
		case 0x1002:
			testcamera.Response(c, r, 0x2001)
		case 0x9201:
			testcamera.Data(c, r, []byte{1, 0, 0, 0})
		case 0x9202:
			testcamera.Data(c, r, []byte{44, 1, 0, 0, 0, 0, 0, 0, 0, 0})
		default:
			testcamera.Response(c, r, 0x2005)
		}
	})
	if _, err := connectTest(t, s, SonyContents); err != nil {
		t.Fatal(err)
	}
}
