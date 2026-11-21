package sony

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"

	"github.com/dancancer/RawLab/tools/camera-transfer/internal/ptpip"
)

type Profile string

const (
	Standard      Profile = "sony-standard-ptp"
	SonyContents  Profile = "sony-pc-contents"
	metadataLimit int64   = 8 << 20
)

type Camera struct {
	client  *ptpip.Client
	Device  Device
	Profile Profile
}

func Probe(ctx context.Context, c *ptpip.Client) (Device, error) {
	var out bytes.Buffer
	if _, err := c.Do(ctx, 0x1001, nil, &out, metadataLimit); err != nil {
		return Device{}, err
	}
	return decodeDevice(out.Bytes())
}

func Connect(ctx context.Context, c *ptpip.Client, profile Profile, model, firmware string) (*Camera, error) {
	if profile != Standard && profile != SonyContents {
		return nil, errors.New("unknown Sony experiment profile")
	}
	if model == "" || firmware == "" {
		return nil, errors.New("expected model and firmware are required")
	}
	d, err := Probe(ctx, c)
	if err != nil {
		return nil, err
	}
	maker := strings.ToLower(strings.TrimSpace(d.Manufacturer))
	if d.Vendor != 17 || (maker != "sony" && maker != "sony corporation") {
		return nil, errors.New("device is not identified as a Sony camera")
	}
	if d.Model != model || d.Firmware != firmware {
		return nil, fmt.Errorf("camera identity mismatch: got %s firmware %s", d.Model, d.Firmware)
	}
	cam := &Camera{client: c, Device: d, Profile: profile}
	ops := []uint16{0x1002, 0x1004, 0x1007, 0x1008, 0x1009}
	if profile == SonyContents {
		ops = []uint16{0x1002, 0x9201, 0x9202, 0x923b, 0x923c, 0x923d}
	}
	for _, op := range ops {
		if !slices.Contains(d.Operations, op) {
			return nil, fmt.Errorf("selected profile requires unadvertised operation 0x%04x", op)
		}
	}
	if _, err = c.Do(ctx, 0x1002, []uint32{1}, nil, 0); err != nil {
		return nil, err
	}
	if profile == SonyContents {
		for _, phase := range []uint32{1, 2} {
			var response bytes.Buffer
			if _, err = c.DoOptionalData(ctx, 0x9201, []uint32{phase, 0, 0}, &response, 64<<10); err != nil {
				return nil, err
			}
		}
		if _, err = cam.read(ctx, 0x9202, []uint32{0x12c, 1}); err != nil {
			return nil, err
		}
		var response bytes.Buffer
		if _, err = c.DoOptionalData(ctx, 0x9201, []uint32{3, 0, 0}, &response, 64<<10); err != nil {
			return nil, err
		}
	}
	return cam, nil
}

func (c *Camera) read(ctx context.Context, op uint16, params []uint32) ([]byte, error) {
	var b bytes.Buffer
	_, err := c.client.Do(ctx, op, params, &b, metadataLimit)
	return b.Bytes(), err
}

// List rejects incomplete listings; max is a budget, never a silent truncation.
func (c *Camera) List(ctx context.Context, storage uint32, max int) ([]Asset, error) {
	if max < 1 || max > 100000 {
		return nil, errors.New("asset limit must be 1..100000")
	}
	if c.Profile == SonyContents {
		return c.listContents(ctx, storage, max)
	}
	b, err := c.read(ctx, 0x1004, nil)
	if err != nil {
		return nil, err
	}
	storages, err := u32s(b, 256)
	if err != nil {
		return nil, err
	}
	if storage != 0 && !slices.Contains(storages, storage) {
		return nil, errors.New("selected storage is not available")
	}
	var assets []Asset
	var seen int
	for _, sid := range storages {
		if sid&0xffff == 0 || (storage != 0 && sid != storage) {
			continue
		}
		b, err = c.read(ctx, 0x1007, []uint32{sid, 0, 0})
		if err != nil {
			return nil, err
		}
		handles, err := u32s(b, max-seen)
		if err != nil {
			return nil, err
		}
		seen += len(handles)
		for _, handle := range handles {
			b, err = c.read(ctx, 0x1008, []uint32{handle})
			if err != nil {
				return nil, err
			}
			a, err := decodeObject(b)
			if err != nil {
				return nil, err
			}
			if a.Storage != sid {
				return nil, errors.New("object moved to another storage while listing")
			}
			a.handle, a.session = handle, c
			if a.Kind != "" {
				assets = append(assets, a)
			}
		}
	}
	return assets, nil
}

func (c *Camera) listContents(ctx context.Context, slot uint32, max int) ([]Asset, error) {
	if slot < 1 || slot > 2 {
		return nil, errors.New("Sony contents profile requires --storage 1 or 2")
	}
	b, err := c.read(ctx, 0x923b, []uint32{slot})
	if err != nil {
		return nil, err
	}
	r := reader{data: b}
	count := r.u32()
	if count > 100000 || uint64(count)*8 != uint64(len(r.data)) {
		return nil, errors.New("invalid Sony date list")
	}
	if count == 0 {
		return []Asset{}, nil
	}
	var after uint64
	var assets []Asset
	seen := map[[2]uint32]bool{}
	for page := 0; page < 1000; page++ {
		b, err = c.read(ctx, 0x923c, []uint32{uint32(after), uint32(after >> 32), 100, slot, 0})
		if err != nil {
			return nil, err
		}
		entries, err := decodeContents(b, slot)
		if err != nil {
			return nil, err
		}
		r = reader{data: b}
		r.take(144)
		pageCount := r.u32()
		for _, a := range entries {
			key := [2]uint32{a.content, uint32(a.file)}
			if seen[key] {
				continue
			}
			seen[key] = true
			if len(seen) > max {
				return nil, errors.New("Sony listing exceeds asset limit")
			}
			a.session = c
			a.listingLimit = max
			if a.Kind != "" {
				assets = append(assets, a)
			}
		}
		if pageCount < 100 {
			return assets, nil
		}
		if len(entries) == 0 || entries[len(entries)-1].createdMS <= after {
			return nil, errors.New("Sony list cursor did not advance; listing incomplete")
		}
		after = entries[len(entries)-1].createdMS
	}
	return nil, errors.New("Sony listing exceeds page budget")
}

func (c *Camera) Download(ctx context.Context, a Asset, w io.Writer, limit int64) error {
	if a.session != c {
		return errors.New("asset belongs to a different camera session; list again")
	}
	if a.Kind == "" || a.Size <= 0 || a.Size > limit {
		return errors.New("unsupported/unknown size or file exceeds download budget")
	}
	if c.Profile == Standard {
		before, err := c.read(ctx, 0x1008, []uint32{a.handle})
		if err != nil {
			return err
		}
		current, err := decodeObject(before)
		if err != nil {
			return err
		}
		if !sameAsset(a, current) {
			return errors.New("camera object changed; list again")
		}
		n, err := c.client.Do(ctx, 0x1009, []uint32{a.handle}, w, a.Size)
		if err != nil {
			return err
		}
		if n != a.Size {
			return errors.New("camera object size differs from metadata")
		}
		after, err := c.read(ctx, 0x1008, []uint32{a.handle})
		if err != nil {
			return err
		}
		if !bytes.Equal(before, after) {
			return errors.New("camera object changed during download")
		}
		return nil
	}
	// New Sony contents reads do not enter SetContentsTransferMode or change settings.
	var offset int64
	for offset < a.Size {
		want := min(int64(4<<20), a.Size-offset)
		requestSize := uint32(want)
		if offset+want == a.Size {
			requestSize |= 1 << 31
		}
		n, err := c.client.Do(ctx, 0x923d, []uint32{a.content, a.Storage<<24 | uint32(a.file), uint32(offset), uint32(uint64(offset) >> 32), requestSize}, w, want)
		if err != nil {
			return err
		}
		if n != want {
			return errors.New("Sony content chunk size mismatch")
		}
		offset += n
	}
	// 在发布原件前复核同一会话的 locator 与元数据，拒绝换卡或删除后重用的对象。
	current, err := c.listContents(ctx, a.Storage, a.listingLimit)
	if err != nil {
		return err
	}
	for _, candidate := range current {
		if candidate.content == a.content && candidate.file == a.file && sameAsset(a, candidate) {
			return nil
		}
	}
	return errors.New("Sony content changed during download; list again")
}

func sameAsset(a, b Asset) bool {
	return a.Name == b.Name && a.Storage == b.Storage && a.Size == b.Size && a.Kind == b.Kind && a.Created == b.Created
}
