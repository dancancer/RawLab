// Package store owns persistent camera originals, independently of editor caches.
package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

type Source struct {
	Name           string `json:"name"`
	Kind           string `json:"kind"`
	Size           int64  `json:"size"`
	Model          string `json:"model"`
	Firmware       string `json:"firmware"`
	CameraID       string `json:"camera_id,omitempty"`
	Profile        string `json:"profile"`
	Storage        uint32 `json:"storage"`
	Created        string `json:"created,omitempty"`
	Representation string `json:"representation"`
}

type Record struct {
	ID       string   `json:"id"`
	SHA256   string   `json:"sha256"`
	State    string   `json:"state"`
	Source   Source   `json:"source"`
	Receipts []Source `json:"receipts"`
	SavedAt  string   `json:"saved_at"`
}

type Attempt struct {
	ID       string `json:"id"`
	SourceID string `json:"source_id,omitempty"`
	State    string `json:"state"`
	Source   Source `json:"source"`
}

type manifest struct {
	Schema     int                `json:"schema_version"`
	ClientGUID string             `json:"client_guid"`
	Sources    map[string]*Record `json:"sources"`
	Attempts   []*Attempt         `json:"attempts"`
}

type Receipt struct {
	SourceID  string `json:"source_id"`
	Path      string `json:"path"`
	SHA256    string `json:"sha256"`
	Bytes     int64  `json:"bytes"`
	State     string `json:"state"`
	Duplicate bool   `json:"duplicate"`
	Integrity string `json:"integrity"`
}

type Store struct {
	root   string
	lock   *os.File
	data   manifest
	mu     sync.Mutex
	closed bool
}

func Open(root string) (*Store, error) {
	absolute, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if err = ensureDirectory(absolute); err != nil {
		return nil, err
	}
	lock, err := lockStore(absolute)
	if err != nil {
		return nil, err
	}
	s := &Store{root: absolute, lock: lock}
	ok := false
	defer func() {
		if !ok {
			s.Close()
		}
	}()
	for _, name := range []string{"files", ".partial"} {
		if err = ensureDirectory(filepath.Join(absolute, name)); err != nil {
			return nil, err
		}
	}
	manifestPath := filepath.Join(absolute, "manifest.json")
	if info, e := os.Lstat(manifestPath); e == nil && (!info.Mode().IsRegular() || info.Size() > 16<<20) {
		return nil, errors.New("invalid or oversized camera manifest")
	}
	b, err := os.ReadFile(manifestPath)
	if errors.Is(err, os.ErrNotExist) {
		guid := make([]byte, 16)
		if _, err = rand.Read(guid); err != nil {
			return nil, err
		}
		s.data = manifest{Schema: 1, ClientGUID: hex.EncodeToString(guid), Sources: map[string]*Record{}, Attempts: []*Attempt{}}
	} else if err != nil {
		return nil, err
	} else if err = json.Unmarshal(b, &s.data); err != nil {
		return nil, fmt.Errorf("invalid camera manifest: %w", err)
	}
	if err = s.validate(); err != nil {
		return nil, err
	}
	if err = s.recover(); err != nil {
		return nil, err
	}
	if err = s.persist(); err != nil {
		return nil, err
	}
	ok = true
	return s, nil
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	return s.lock.Close()
}

func (s *Store) GUID() [16]byte {
	var id [16]byte
	b, _ := hex.DecodeString(s.data.ClientGUID)
	copy(id[:], b)
	return id
}

func (s *Store) Records() []Record {
	s.mu.Lock()
	defer s.mu.Unlock()
	var records []Record
	for _, r := range s.data.Sources {
		if r.State != "interrupted" {
			v := *r
			v.Receipts = append([]Source(nil), r.Receipts...)
			records = append(records, v)
		}
	}
	sort.Slice(records, func(i, j int) bool { return records[i].SavedAt < records[j].SavedAt })
	return records
}

func (s *Store) Receive(ctx context.Context, source Source, download func(io.Writer) error) (Receipt, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return Receipt{}, errors.New("camera store is closed")
	}
	if err := validSource(source); err != nil {
		return Receipt{}, err
	}
	if err := ctx.Err(); err != nil {
		return Receipt{}, err
	}
	id, err := newID()
	if err != nil {
		return Receipt{}, err
	}
	attempt := &Attempt{ID: id, State: "transferring", Source: source}
	s.data.Attempts = append(s.data.Attempts, attempt)
	if err = s.persist(); err != nil {
		return Receipt{}, err
	}
	partial := s.partialPath(id)
	f, err := os.OpenFile(partial, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return Receipt{}, err
	}
	// Removing only our partial is safe even if publication/manifest completion fails.
	defer func() { f.Close(); os.Remove(partial) }()
	h := sha256.New()
	w := &boundedWriter{ctx: ctx, w: io.MultiWriter(f, h), limit: source.Size}
	err = download(w)
	if err == nil {
		err = ctx.Err()
	}
	if err == nil && w.n != source.Size {
		err = errors.New("download size differs from camera metadata")
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = checkFormat(partial, source.Kind)
	}
	if err != nil {
		attempt.State = "failed"
		if ctx.Err() != nil {
			attempt.State = "cancelled"
		}
		return Receipt{}, errors.Join(err, s.persist())
	}
	digest := hex.EncodeToString(h.Sum(nil))
	for _, existing := range s.data.Sources {
		if existing.State != "committed" || existing.SHA256 != digest || existing.Source.Size != source.Size || existing.Source.Kind != source.Kind {
			continue
		}
		if err = s.checkRecord(existing); err != nil {
			existing.State = stateForError(err)
			continue
		}
		if !slices.Contains(existing.Receipts, source) {
			existing.Receipts = append(existing.Receipts, source)
		}
		attempt.SourceID, attempt.State = existing.ID, "saved"
		if err = s.persist(); err != nil {
			return Receipt{}, err
		}
		return s.receipt(existing, true), nil
	}
	r := &Record{ID: id, SHA256: digest, State: "publishPrepared", Source: source, Receipts: []Source{source}, SavedAt: time.Now().UTC().Format(time.RFC3339Nano)}
	s.data.Sources[id] = r
	attempt.SourceID, attempt.State = id, "publishPrepared"
	if err = s.persist(); err != nil {
		return Receipt{}, err
	}
	final := s.path(r)
	if err = ensureDirectory(filepath.Dir(final)); err != nil {
		return Receipt{}, err
	}
	if _, err = os.Lstat(final); !errors.Is(err, os.ErrNotExist) {
		return Receipt{}, errors.New("reserved camera path already exists")
	}
	if err = os.Rename(partial, final); err != nil {
		return Receipt{}, err
	}
	if err = syncDirectory(filepath.Dir(final)); err != nil {
		return Receipt{}, err
	}
	if err = syncDirectory(filepath.Join(s.root, "files")); err != nil {
		return Receipt{}, err
	}
	r.State, attempt.State = "committed", "saved"
	if err = s.persist(); err != nil {
		return Receipt{}, err
	}
	return s.receipt(r, false), nil
}

func (s *Store) Resolve(id string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return "", errors.New("camera store is closed")
	}
	r := s.data.Sources[id]
	if r == nil {
		return "", errors.New("unknown camera source id")
	}
	if r.State != "committed" && r.State != "sourceUnavailable" {
		return "", fmt.Errorf("source is %s; original is retained if present", r.State)
	}
	if err := s.checkRecord(r); err != nil {
		r.State = stateForError(err)
		return "", errors.Join(err, s.persist())
	}
	r.State = "committed"
	return s.path(r), nil
}

func (s *Store) Verify(id, reference string) (bool, error) {
	stored, err := s.Resolve(id)
	if err != nil {
		return false, err
	}
	one, n, err := hashFile(stored)
	if err != nil {
		return false, err
	}
	two, m, err := hashFile(reference)
	if err != nil {
		return false, err
	}
	return one == two && n == m, nil
}

func (s *Store) receipt(r *Record, duplicate bool) Receipt {
	return Receipt{SourceID: r.ID, Path: s.path(r), SHA256: r.SHA256, Bytes: r.Source.Size, State: "saved", Duplicate: duplicate, Integrity: "protocol-length-format; camera-original-hash-not-compared"}
}
func (s *Store) path(r *Record) string { return filepath.Join(s.root, "files", r.ID, r.Source.Name) }
func (s *Store) partialPath(id string) string {
	return filepath.Join(s.root, ".partial", id+".partial")
}

func validSource(s Source) error {
	if s.Size <= 0 || s.Size > 16<<30 {
		return errors.New("camera file size must be positive and at most 16 GiB")
	}
	if len(s.Name) == 0 || len(s.Name) > 240 || strings.ContainsAny(s.Name, "/\\:\x00") || s.Name == "." || s.Name == ".." {
		return errors.New("unsafe camera filename")
	}
	for _, r := range s.Name {
		if r < 32 || r == 127 {
			return errors.New("control character in filename")
		}
	}
	ext := strings.ToLower(filepath.Ext(s.Name))
	valid := s.Kind == "arw" && ext == ".arw" || s.Kind == "jpeg" && (ext == ".jpg" || ext == ".jpeg") || s.Kind == "heif" && (ext == ".hif" || ext == ".heif" || ext == ".heic")
	if !valid {
		return errors.New("camera image extension and representation disagree")
	}
	if len(s.Model) > 256 || len(s.Firmware) > 128 || len(s.CameraID) > 128 || len(s.Profile) > 128 || len(s.Created) > 256 {
		return errors.New("oversized camera metadata")
	}
	return nil
}

func newID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	h := hex.EncodeToString(b[:])
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:], nil
}
func validID(id string) bool {
	if len(id) != 36 || id[8] != '-' || id[13] != '-' || id[18] != '-' || id[23] != '-' {
		return false
	}
	b, err := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	return err == nil && len(b) == 16
}

type boundedWriter struct {
	ctx      context.Context
	w        io.Writer
	n, limit int64
}

func (w *boundedWriter) Write(b []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	if int64(len(b)) > w.limit-w.n {
		return 0, errors.New("download exceeds expected file length")
	}
	n, err := w.w.Write(b)
	w.n += int64(n)
	return n, err
}

func ensureDirectory(p string) error {
	if err := os.MkdirAll(p, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(p)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("camera store directory is not a real directory")
	}
	return nil
}
func syncDirectory(p string) error {
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

func hashFile(p string) (string, int64, error) {
	info, err := os.Lstat(p)
	if err != nil {
		return "", 0, err
	}
	if !info.Mode().IsRegular() {
		return "", 0, errors.New("source is not a regular file")
	}
	f, err := os.Open(p)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), n, err
}

func checkFormat(p, kind string) error {
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	defer f.Close()
	var header [16]byte
	n, err := f.Read(header[:])
	if err != nil && err != io.EOF {
		return err
	}
	valid := false
	switch kind {
	case "arw":
		valid = n >= 8 && (string(header[:4]) == "II*\x00" || string(header[:4]) == "MM\x00*")
	case "jpeg":
		valid = n >= 3 && header[0] == 255 && header[1] == 216 && header[2] == 255
		if valid {
			var end [2]byte
			if _, err = f.Seek(-2, io.SeekEnd); err != nil {
				return err
			}
			_, err = io.ReadFull(f, end[:])
			valid = err == nil && end == [2]byte{255, 217}
		}
	case "heif":
		valid = n >= 12 && string(header[4:8]) == "ftyp" && strings.Contains(" heic heix hevc hevx mif1 msf1 ", " "+string(header[8:12])+" ")
	}
	if !valid {
		return errors.New("received file does not match requested camera format")
	}
	return nil
}
