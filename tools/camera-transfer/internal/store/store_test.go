package store

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

var rawBytes = []byte{'I', 'I', 42, 0, 8, 0, 0, 0, 1, 2, 3, 4}

func source() Source {
	return Source{Name: "DSC00001.ARW", Kind: "arw", Size: int64(len(rawBytes)), Model: "ILCE-7CM2", Firmware: "test", Profile: "synthetic"}
}
func receive(s *Store, data []byte) (Receipt, error) {
	src := source()
	src.Size = int64(len(data))
	return s.Receive(context.Background(), src, func(w io.Writer) error { _, err := w.Write(data); return err })
}

func TestPersistentOriginalSurvivesReopenAndDuplicateKeepsPath(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	one, err := receive(s, rawBytes)
	if err != nil {
		t.Fatal(err)
	}
	two, err := receive(s, rawBytes)
	if err != nil {
		t.Fatal(err)
	}
	if one.SourceID != two.SourceID || one.Path != two.Path || !two.Duplicate {
		t.Fatalf("%+v %+v", one, two)
	}
	s.Close()
	s, err = Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	path, err := s.Resolve(one.SourceID)
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(b, rawBytes) {
		t.Fatalf("original lost: %v", err)
	}
	if len(s.Records()) != 1 {
		t.Fatalf("records=%+v", s.Records())
	}
}

func TestSameNameDifferentBytesNeverOverwrite(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	one, err := receive(s, rawBytes)
	if err != nil {
		t.Fatal(err)
	}
	different := append(append([]byte(nil), rawBytes...), 9)
	two, err := receive(s, different)
	if err != nil {
		t.Fatal(err)
	}
	if one.SourceID == two.SourceID || one.Path == two.Path {
		t.Fatal("filename collision")
	}
	b, _ := os.ReadFile(one.Path)
	if !bytes.Equal(b, rawBytes) {
		t.Fatal("overwrote original")
	}
}

func TestInvalidTransferNeverPublishesAndRemovesPartial(t *testing.T) {
	for _, kind := range []string{"short", "jpeg-instead-of-raw", "network-error", "cancelled", "unsafe-name"} {
		t.Run(kind, func(t *testing.T) {
			root := t.TempDir()
			s, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			src := source()
			if kind == "unsafe-name" {
				src.Name = "../../outside.ARW"
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			_, err = s.Receive(ctx, src, func(w io.Writer) error {
				b := rawBytes
				if kind == "short" {
					b = b[:4]
				}
				if kind == "jpeg-instead-of-raw" {
					b = []byte{255, 216, 255, 0, 0, 0, 0, 0, 0, 0, 255, 217}
				}
				_, err := w.Write(b)
				if err != nil {
					return err
				}
				if kind == "network-error" {
					return errors.New("camera disconnected")
				}
				if kind == "cancelled" {
					cancel()
				}
				return nil
			})
			if err == nil {
				t.Fatal("accepted invalid transfer")
			}
			if len(s.Records()) != 0 {
				t.Fatal("published invalid source")
			}
			filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
				if err == nil && !d.IsDir() && filepath.Ext(p) == ".partial" {
					t.Error("left partial", p)
				}
				return nil
			})
		})
	}
}

func TestRecoveryClaimsAlreadyPublishedSource(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	one, err := receive(s, rawBytes)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	// Simulate the window after rename but before the final manifest commit.
	manifestPath := filepath.Join(root, "manifest.json")
	b, _ := os.ReadFile(manifestPath)
	var m map[string]any
	if err = json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	sources := m["sources"].(map[string]any)
	sources[one.SourceID].(map[string]any)["state"] = "publishPrepared"
	for _, v := range m["attempts"].([]any) {
		v.(map[string]any)["state"] = "publishPrepared"
	}
	b, _ = json.Marshal(m)
	if err = os.WriteFile(manifestPath, b, 0600); err != nil {
		t.Fatal(err)
	}
	s, err = Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	p, err := s.Resolve(one.SourceID)
	if err != nil || p != one.Path {
		t.Fatalf("%s %v", p, err)
	}
	if len(s.Records()) != 1 {
		t.Fatal("recovery duplicated source")
	}
}

func TestChangedOriginalIsNotReusedOrOpened(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	one, err := receive(s, rawBytes)
	if err != nil {
		t.Fatal(err)
	}
	corrupt := append([]byte(nil), rawBytes...)
	corrupt[8] = 99
	if err = os.WriteFile(one.Path, corrupt, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Resolve(one.SourceID); err == nil {
		t.Fatal("accepted changed source")
	}
	two, err := receive(s, rawBytes)
	if err != nil {
		t.Fatal(err)
	}
	if one.SourceID == two.SourceID {
		t.Fatal("deduplicated against corrupt file")
	}
	b, _ := os.ReadFile(one.Path)
	if !bytes.Equal(b, corrupt) {
		t.Fatal("silently overwrote changed source")
	}
}

func TestStoreHasExclusiveWriterAndRejectsManifestPathInjection(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := Open(root); err == nil {
		second.Close()
		t.Error("opened second writer")
	}
	s.Close()
	bad := `{"schema_version":1,"client_guid":"00112233445566778899aabbccddeeff","sources":{"../../outside":{"id":"../../outside","kind":"arw","state":"committed"}},"attempts":[]}`
	if err = os.WriteFile(filepath.Join(root, "manifest.json"), []byte(bad), 0600); err != nil {
		t.Fatal(err)
	}
	if s, err = Open(root); err == nil {
		s.Close()
		t.Fatal("accepted path injection")
	}
}

func TestRepeatedDownloadsKeepRecoveryHistoryBounded(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for i := 0; i < 140; i++ {
		if _, err = receive(s, rawBytes); err != nil {
			t.Fatal(err)
		}
	}
	if len(s.data.Attempts) > 128 {
		t.Fatalf("retained %d completed attempts", len(s.data.Attempts))
	}
	records := s.Records()
	if len(records) != 1 || len(records[0].Receipts) != 1 {
		t.Fatal("duplicate provenance grows without a new source")
	}
}
