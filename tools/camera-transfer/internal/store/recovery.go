package store

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

func (s *Store) validate() error {
	guid, err := hex.DecodeString(s.data.ClientGUID)
	if s.data.Schema != 1 || err != nil || len(guid) != 16 || s.data.Sources == nil {
		return errors.New("unsupported or invalid camera manifest")
	}
	if len(s.data.Sources) > 100000 || len(s.data.Attempts) > 100000 {
		return errors.New("camera manifest entry limit exceeded")
	}
	for id, r := range s.data.Sources {
		if r == nil || !validID(id) || r.ID != id {
			return errors.New("invalid camera source identity")
		}
		if err := validSource(r.Source); err != nil {
			return err
		}
		hash, err := hex.DecodeString(r.SHA256)
		if err != nil || len(hash) != 32 {
			return errors.New("invalid stored content digest")
		}
		switch r.State {
		case "publishPrepared", "committed", "sourceMissing", "sourceChanged", "sourceUnavailable", "interrupted":
		default:
			return errors.New("unknown camera source state")
		}
	}
	for _, a := range s.data.Attempts {
		if a == nil || !validID(a.ID) || (a.SourceID != "" && !validID(a.SourceID)) {
			return errors.New("invalid camera attempt")
		}
	}
	return nil
}

func (s *Store) persist() error {
	// 仅保留最近的终态记录；活跃事务始终保留，以便恢复未完成的发布。
	if len(s.data.Attempts) > 128 {
		retained := make([]*Attempt, 0, 128)
		for i, a := range s.data.Attempts {
			if i >= len(s.data.Attempts)-128 || a.State == "transferring" || a.State == "publishPrepared" {
				retained = append(retained, a)
			}
		}
		s.data.Attempts = retained
	}
	b, err := json.MarshalIndent(s.data, "", "  ")
	if err != nil {
		return err
	}
	if len(b) > 16<<20 {
		return errors.New("camera manifest exceeds 16 MiB")
	}
	f, err := os.CreateTemp(s.root, ".manifest-")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err = f.Write(append(b, '\n')); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(name, filepath.Join(s.root, "manifest.json")); err != nil {
		return err
	}
	return syncDirectory(s.root)
}

func (s *Store) checkRecord(r *Record) error {
	directory := filepath.Dir(s.path(r))
	info, err := os.Lstat(directory)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("source directory changed")
	}
	hash, n, err := hashFile(s.path(r))
	if err != nil {
		return err
	}
	if hash != r.SHA256 || n != r.Source.Size {
		return errors.New("source bytes changed")
	}
	return nil
}

func stateForError(err error) string {
	if errors.Is(err, os.ErrNotExist) {
		return "sourceMissing"
	}
	if errors.Is(err, os.ErrPermission) {
		return "sourceUnavailable"
	}
	return "sourceChanged"
}

func (s *Store) recover() error {
	for _, r := range s.data.Sources {
		if r.State == "interrupted" {
			continue
		}
		err := s.checkRecord(r)
		if r.State == "publishPrepared" && errors.Is(err, os.ErrNotExist) {
			r.State = "interrupted"
		} else if err != nil {
			r.State = stateForError(err)
		} else {
			r.State = "committed"
		}
	}
	for _, a := range s.data.Attempts {
		if a.State == "transferring" || a.State == "publishPrepared" {
			if r := s.data.Sources[a.SourceID]; r != nil && r.State == "committed" {
				a.State = "saved"
			} else {
				a.State = "interrupted"
			}
		}
		// 终态落盘与 Receive 的 defer 之间也可能退出；裁剪清单前清理每个已登记 partial。
		if err := os.Remove(s.partialPath(a.ID)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("clean registered partial: %w", err)
		}
	}
	// Unreferenced complete files are deliberately retained. They are never imported
	// without a manifest; the user can recover them explicitly through the file picker.
	return nil
}
