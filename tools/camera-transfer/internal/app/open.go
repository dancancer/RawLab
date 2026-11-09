package app

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

func OpenMac(ctx context.Context, application, path string) error {
	if runtime.GOOS != "darwin" {
		return errors.New("this experiment only integrates macOS system opening")
	}
	if !filepath.IsAbs(application) || !strings.HasSuffix(application, ".app") {
		return errors.New("--app must be an absolute .app path")
	}
	if info, err := os.Stat(filepath.Join(application, "Contents", "Info.plist")); err != nil || !info.Mode().IsRegular() {
		return errors.New("application bundle is unavailable")
	}
	if !filepath.IsAbs(path) {
		return errors.New("source path must be absolute")
	}
	// No shell and no --args: this is a system file-open event, not a command line.
	if err := exec.CommandContext(ctx, "/usr/bin/open", "-a", application, path).Run(); err != nil {
		return errors.New("LaunchServices did not accept the open request")
	}
	return nil
}
