package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/dancancer/RawLab/tools/camera-transfer/internal/testcamera"
)

func TestCLITransferVerifyAndExplicitOpen(t *testing.T) {
	raw := []byte{'I', 'I', 42, 0, 8, 0, 0, 0, 1, 2, 3, 4}
	s := testcamera.Start(t, func(c net.Conn, r testcamera.Request) {
		switch r.Op {
		case 0x1001:
			testcamera.Data(c, r, testcamera.Device("ILCE-7CM2", "2.00"))
		case 0x1002, 0x1003:
			testcamera.Response(c, r, 0x2001)
		case 0x1004:
			testcamera.Data(c, r, append(testcamera.U32(1), testcamera.U32(0x10001)...))
		case 0x1007:
			testcamera.Data(c, r, append(testcamera.U32(1), testcamera.U32(42)...))
		case 0x1008:
			testcamera.Data(c, r, testcamera.Object("DSC00001.ARW", uint32(len(raw)), 0xb101))
		case 0x1009:
			testcamera.Data(c, r, raw)
		default:
			testcamera.Response(c, r, 0x2005)
		}
	})
	host, port, _ := net.SplitHostPort(s.Address)
	root := filepath.Join(t.TempDir(), "camera store")
	connection := []string{"--experimental", "--host", host, "--port", port, "--transport", "plain", "--profile", "sony-standard-ptp", "--model", "ILCE-7CM2", "--firmware", "2.00", "--store", root}
	var out, diagnostics bytes.Buffer
	runner := Runner{Out: &out, Err: &diagnostics}
	if code := runner.Run(context.Background(), append([]string{"list"}, connection...)); code != 0 {
		t.Fatalf("list %d: %s", code, diagnostics.String())
	}
	if !bytes.Contains(out.Bytes(), []byte("DSC00001.ARW")) {
		t.Fatal(out.String())
	}
	out.Reset()
	diagnostics.Reset()
	args := append([]string{"download"}, connection...)
	args = append(args, "--file-name", "DSC00001.ARW", "--expect-size", "12")
	if code := runner.Run(context.Background(), args); code != 0 {
		t.Fatalf("download %d: %s", code, diagnostics.String())
	}
	var receipt struct {
		SourceID string `json:"source_id"`
		Path     string `json:"path"`
		State    string `json:"state"`
	}
	if err := json.Unmarshal(out.Bytes(), &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.State != "saved" {
		t.Fatal(out.String())
	}
	b, err := os.ReadFile(receipt.Path)
	if err != nil || !bytes.Equal(b, raw) {
		t.Fatal("source bytes changed")
	}
	// Verification compares a separate file, not the manifest's cached digest.
	reference := filepath.Join(t.TempDir(), "reader.ARW")
	if err = os.WriteFile(reference, raw, 0600); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	diagnostics.Reset()
	if code := runner.Run(context.Background(), []string{"verify", "--store", root, "--source", receipt.SourceID, "--reference", reference}); code != 0 {
		t.Fatalf("verify %d %s", code, diagnostics.String())
	}
	if !bytes.Contains(out.Bytes(), []byte(`"matches": true`)) {
		t.Fatal(out.String())
	}
	opened := false
	runner.Launch = func(_ context.Context, application, path string) error {
		opened = true
		if path != receipt.Path || application != "/test/RawLab Mac.app" {
			t.Errorf("incorrect open %s %s", application, path)
		}
		return errors.New("application unavailable")
	}
	out.Reset()
	diagnostics.Reset()
	if code := runner.Run(context.Background(), []string{"open", "--store", root, "--source", receipt.SourceID, "--app", "/test/RawLab Mac.app"}); code == 0 {
		t.Fatal("reported failed open as success")
	}
	if !opened {
		t.Fatal("did not hand off verified local file")
	}
	if _, err = os.Stat(receipt.Path); err != nil {
		t.Fatal("open failure deleted source")
	}
}

func TestNetworkRequiresExplicitExperimentAndLocalAddress(t *testing.T) {
	for _, args := range [][]string{
		{"probe", "--host", "127.0.0.1", "--transport", "plain"},
		{"probe", "--experimental", "--host", "8.8.8.8", "--transport", "plain"},
		{"probe", "--experimental", "--host", "camera.example", "--transport", "plain"},
	} {
		var out, diagnostics bytes.Buffer
		if code := (&Runner{Out: &out, Err: &diagnostics}).Run(context.Background(), args); code == 0 {
			t.Fatalf("accepted %v", args)
		}
	}
}

func TestCredentialsRejectWorldReadableAndNeverEchoSecrets(t *testing.T) {
	p := filepath.Join(t.TempDir(), "credentials.json")
	if err := os.WriteFile(p, []byte(`{"user":"camera","password":"SECRET-DO-NOT-PRINT","fingerprint":"bad"}`), 0644); err != nil {
		t.Fatal(err)
	}
	var out, diagnostics bytes.Buffer
	args := []string{"probe", "--experimental", "--host", "127.0.0.1", "--credentials", p, "--store", t.TempDir()}
	if code := (&Runner{Out: &out, Err: &diagnostics}).Run(context.Background(), args); code == 0 {
		t.Fatal("insecure credentials accepted")
	}
	if bytes.Contains(out.Bytes(), []byte("SECRET-DO-NOT-PRINT")) || bytes.Contains(diagnostics.Bytes(), []byte("SECRET-DO-NOT-PRINT")) {
		t.Fatal("secret leaked")
	}
}
