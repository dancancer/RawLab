package app

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/dancancer/RawLab/tools/camera-transfer/internal/ptpip"
	"github.com/dancancer/RawLab/tools/camera-transfer/internal/sony"
	"github.com/dancancer/RawLab/tools/camera-transfer/internal/store"
)

type Runner struct {
	Out, Err io.Writer
	Launch   func(context.Context, string, string) error
}

type options struct {
	command, host, transport, credentials, profile, model, firmware, root, name, source, reference, application string
	experimental                                                                                                bool
	port, sshPort, maxAssets                                                                                    int
	storage                                                                                                     uint
	maxBytes, expectSize                                                                                        int64
	timeout                                                                                                     time.Duration
}

func (r *Runner) Run(ctx context.Context, args []string) int {
	if r.Out == nil {
		r.Out = io.Discard
	}
	if r.Err == nil {
		r.Err = io.Discard
	}
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" {
		fmt.Fprintln(r.Out, "rawlab-camera <probe|list|download|records|verify|open> [options]\nSony desktop experiment. Network commands require --experimental and an explicit local IP.\nUse <command> --help for options. No camera support is implied by a successful build.")
		return 0
	}
	opts, err := r.parse(args)
	if errors.Is(err, flag.ErrHelp) {
		return 0
	}
	if err != nil {
		fmt.Fprintln(r.Err, "ERROR:", err)
		return 2
	}
	if err = r.execute(ctx, opts); err != nil {
		fmt.Fprintln(r.Err, "ERROR:", err)
		if errors.Is(err, context.Canceled) {
			return 130
		}
		return 1
	}
	return 0
}

func (r *Runner) parse(args []string) (options, error) {
	o := options{command: args[0]}
	fs := flag.NewFlagSet(o.command, flag.ContinueOnError)
	fs.SetOutput(r.Err)
	fs.StringVar(&o.host, "host", "", "explicit private/link-local/loopback camera IP (no discovery)")
	fs.BoolVar(&o.experimental, "experimental", false, "enable an unverified Sony protocol experiment")
	fs.StringVar(&o.transport, "transport", "ssh", "ssh or explicitly selected plain PTP/IP")
	fs.StringVar(&o.credentials, "credentials", "", "0600 JSON with user, password, fingerprint; never logged")
	fs.IntVar(&o.port, "port", 15740, "PTP/IP port; SSH forwarding is fixed to 15740")
	fs.IntVar(&o.sshPort, "ssh-port", 22, "SSH authentication port")
	fs.DurationVar(&o.timeout, "timeout", 15*time.Second, "maximum time waiting for a protocol packet")
	fs.StringVar(&o.profile, "profile", string(sony.Standard), "sony-standard-ptp or sony-pc-contents")
	fs.StringVar(&o.model, "model", "", "exact expected Sony model from probe")
	fs.StringVar(&o.firmware, "firmware", "", "exact expected firmware from probe")
	fs.UintVar(&o.storage, "storage", 0, "standard storage ID, or Sony contents slot 1/2 (default 1)")
	fs.IntVar(&o.maxAssets, "max-assets", 10000, "fail instead of truncating listings above this count")
	fs.Int64Var(&o.maxBytes, "max-bytes", 1<<30, "maximum single file size in bytes")
	fs.Int64Var(&o.expectSize, "expect-size", 0, "optional expected file size from a previous listing")
	fs.StringVar(&o.root, "store", "", "persistent camera store (default: user config/RawLab/CameraImports)")
	fs.StringVar(&o.name, "file-name", "", "exact filename to download, freshly selected in the current session")
	fs.StringVar(&o.source, "source", "", "persistent source ID for verify/open")
	fs.StringVar(&o.reference, "reference", "", "independent card-reader file for byte comparison")
	fs.StringVar(&o.application, "app", "", "explicit absolute macOS RawLab .app path")
	if err := fs.Parse(args[1:]); err != nil {
		return o, err
	}
	if fs.NArg() != 0 {
		return o, errors.New("unexpected positional arguments")
	}
	switch o.command {
	case "probe", "list", "download", "records", "verify", "open":
	default:
		return o, errors.New("unknown command")
	}
	if o.root == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return o, err
		}
		o.root = filepath.Join(base, "RawLab", "CameraImports")
	}
	if o.command == "probe" || o.command == "list" || o.command == "download" {
		if !o.experimental {
			return o, errors.New("network operations require --experimental; these are not certified camera profiles")
		}
		ip, err := netip.ParseAddr(o.host)
		if err != nil || (!ip.IsPrivate() && !ip.IsLinkLocalUnicast() && !ip.IsLoopback()) {
			return o, errors.New("--host must be an explicit local camera IP")
		}
		if o.transport != "plain" && o.transport != "ssh" {
			return o, errors.New("transport must be ssh or plain")
		}
		if o.port < 1 || o.port > 65535 || o.sshPort < 1 || o.sshPort > 65535 {
			return o, errors.New("invalid camera port")
		}
		if o.transport == "ssh" && (o.credentials == "" || o.port != 15740) {
			return o, errors.New("SSH requires --credentials and PTP port 15740")
		}
		if o.timeout < time.Second || o.timeout > 5*time.Minute {
			return o, errors.New("timeout must be between 1s and 5m")
		}
		if o.maxAssets < 1 || o.maxAssets > 100000 || o.storage > 0xffffffff {
			return o, errors.New("invalid listing budget/storage")
		}
		if o.maxBytes < 1 || o.maxBytes > 16<<30 || o.expectSize < 0 {
			return o, errors.New("invalid file byte budget")
		}
		if o.command != "probe" && (o.model == "" || o.firmware == "") {
			return o, errors.New("list/download require --model and --firmware from probe")
		}
		if o.profile != string(sony.Standard) && o.profile != string(sony.SonyContents) {
			return o, errors.New("unknown camera profile")
		}
	}
	if o.command == "download" && o.name == "" {
		return o, errors.New("download requires --file-name")
	}
	if (o.command == "open" || o.command == "verify") && o.source == "" {
		return o, errors.New("--source is required")
	}
	if o.command == "open" && o.application == "" {
		return o, errors.New("open requires --app")
	}
	if o.command == "verify" && o.reference == "" {
		return o, errors.New("verify requires an independent --reference file")
	}
	return o, nil
}

func (r *Runner) execute(ctx context.Context, o options) error {
	s, err := store.Open(o.root)
	if err != nil {
		return err
	}
	defer s.Close()
	switch o.command {
	case "records":
		return r.output(s.Records())
	case "verify":
		matches, err := s.Verify(o.source, o.reference)
		if err != nil {
			return err
		}
		if err = r.output(map[string]any{"source_id": o.source, "matches": matches, "check": "SHA-256 and byte length against supplied reference"}); err != nil {
			return err
		}
		if !matches {
			return errors.New("downloaded bytes do not match the supplied reference")
		}
		return nil
	case "open":
		path, err := s.Resolve(o.source)
		if err != nil {
			return err
		}
		launch := r.Launch
		if launch == nil {
			launch = OpenMac
		}
		if err = launch(ctx, o.application, path); err != nil {
			return fmt.Errorf("original saved; application open failed: %w", err)
		}
		return r.output(map[string]any{"source_id": o.source, "path": path, "state": "open_requested", "note": "system accepted request; preview/edit success must be observed in RawLab"})
	}
	ptpOpts := ptpip.Options{GUID: s.GUID(), Timeout: o.timeout}
	if o.transport == "ssh" {
		credentials, err := loadCredentials(o.credentials)
		if err != nil {
			return err
		}
		credentials.Timeout = o.timeout
		tunnel, err := ptpip.ConnectSSH(ctx, net.JoinHostPort(o.host, strconv.Itoa(o.sshPort)), credentials)
		if err != nil {
			return err
		}
		defer tunnel.Close()
		ptpOpts.DialContext = tunnel.DialContext
	}
	c, err := ptpip.Dial(ctx, net.JoinHostPort(o.host, strconv.Itoa(o.port)), ptpOpts)
	if err != nil {
		return err
	}
	defer c.Close()
	if o.command == "probe" {
		device, err := sony.Probe(ctx, c)
		if err != nil {
			return err
		}
		return r.output(map[string]any{"device": device, "validation": "experimental; capability advertisements are not transfer proof"})
	}
	cam, err := sony.Connect(ctx, c, sony.Profile(o.profile), o.model, o.firmware)
	if err != nil {
		return err
	}
	storage := uint32(o.storage)
	if o.profile == string(sony.SonyContents) && storage == 0 {
		storage = 1
	}
	assets, err := cam.List(ctx, storage, o.maxAssets)
	if err != nil {
		return err
	}
	if o.command == "list" {
		return r.output(map[string]any{"device": cam.Device, "profile": o.profile, "validation": "experimental", "assets": assets})
	}
	var matches []sony.Asset
	for _, a := range assets {
		if a.Name == o.name {
			matches = append(matches, a)
		}
	}
	if len(matches) != 1 {
		return fmt.Errorf("filename matched %d current assets; select an exact name and storage", len(matches))
	}
	a := matches[0]
	if a.Size <= 0 || a.Size > o.maxBytes {
		return errors.New("file size is unknown or exceeds --max-bytes")
	}
	if o.expectSize != 0 && a.Size != o.expectSize {
		return errors.New("camera file size changed since selection")
	}
	source := store.Source{Name: a.Name, Kind: a.Kind, Size: a.Size, Model: cam.Device.Model, Firmware: cam.Device.Firmware, CameraID: cam.Device.CameraID, Profile: o.profile, Storage: a.Storage, Created: a.Created, Representation: a.Representation}
	fmt.Fprintf(r.Err, "Receiving %s (%d bytes); original byte comparison is a separate verify step.\n", a.Name, a.Size)
	receipt, err := s.Receive(ctx, source, func(w io.Writer) error {
		return cam.Download(ctx, a, &progressWriter{w: w, out: r.Err, total: a.Size}, o.maxBytes)
	})
	if err != nil {
		return err
	}
	return r.output(receipt)
}

func (r *Runner) output(value any) error {
	enc := json.NewEncoder(r.Out)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}

func loadCredentials(path string) (ptpip.SSHOptions, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return ptpip.SSHOptions{}, errors.New("cannot access local camera credentials")
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 8192 {
		return ptpip.SSHOptions{}, errors.New("credentials must be a private regular file (chmod 600), at most 8192 bytes")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ptpip.SSHOptions{}, errors.New("cannot read local camera credentials")
	}
	var cfg struct {
		User        string `json:"user"`
		Password    string `json:"password"`
		Fingerprint string `json:"fingerprint"`
	}
	if json.Unmarshal(b, &cfg) != nil {
		return ptpip.SSHOptions{}, errors.New("invalid credentials JSON (user/password/fingerprint)")
	}
	return ptpip.SSHOptions{User: cfg.User, Password: cfg.Password, Fingerprint: cfg.Fingerprint}, nil
}

type progressWriter struct {
	w        io.Writer
	out      io.Writer
	n, total int64
	last     time.Time
}

func (w *progressWriter) Write(b []byte) (int, error) {
	n, err := w.w.Write(b)
	w.n += int64(n)
	if time.Since(w.last) > time.Second || w.n == w.total {
		fmt.Fprintf(w.out, "Received %d / %d bytes\n", w.n, w.total)
		w.last = time.Now()
	}
	return n, err
}
