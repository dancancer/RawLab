//go:build darwin || linux

package store

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

func lockStore(root string) (*os.File, error) {
	p := filepath.Join(root, ".lock")
	f, err := os.OpenFile(p, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("camera store is already in use: %w", err)
	}
	return f, nil
}
