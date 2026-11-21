package sony

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"path"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// Wire layouts are documented by the Apache-2.0 alpha2go project.
// See THIRD_PARTY_NOTICES.md. Parsing here is independently bounded and fail-closed.
type reader struct {
	data []byte
	err  error
}

func (r *reader) take(n int) []byte {
	if r.err != nil {
		return nil
	}
	if n < 0 || n > len(r.data) {
		r.err = io.ErrUnexpectedEOF
		return nil
	}
	b := r.data[:n]
	r.data = r.data[n:]
	return b
}
func (r *reader) u8() uint8 {
	b := r.take(1)
	if b == nil {
		return 0
	}
	return b[0]
}
func (r *reader) u16() uint16 {
	b := r.take(2)
	if b == nil {
		return 0
	}
	return binary.LittleEndian.Uint16(b)
}
func (r *reader) u32() uint32 {
	b := r.take(4)
	if b == nil {
		return 0
	}
	return binary.LittleEndian.Uint32(b)
}
func (r *reader) u64() uint64 {
	b := r.take(8)
	if b == nil {
		return 0
	}
	return binary.LittleEndian.Uint64(b)
}
func (r *reader) str() string {
	n := int(r.u8())
	if n == 0 {
		return ""
	}
	b := r.take(2 * n)
	if b == nil {
		return ""
	}
	if binary.LittleEndian.Uint16(b[len(b)-2:]) != 0 {
		r.err = errors.New("unterminated PTP string")
		return ""
	}
	u := make([]uint16, n-1)
	for i := range u {
		u[i] = binary.LittleEndian.Uint16(b[2*i:])
	}
	s := string(utf16.Decode(u))
	if strings.ContainsRune(s, 0) {
		r.err = errors.New("embedded NUL in PTP string")
	}
	return s
}
func (r *reader) u16s() []uint16 {
	n := r.u32()
	if n > 4096 || uint64(n)*2 > uint64(len(r.data)) {
		r.err = errors.New("invalid PTP array size")
		return nil
	}
	v := make([]uint16, n)
	for i := range v {
		v[i] = r.u16()
	}
	return v
}

type Device struct {
	Manufacturer string   `json:"manufacturer"`
	Model        string   `json:"model"`
	Firmware     string   `json:"firmware"`
	CameraID     string   `json:"camera_id"`
	Operations   []uint16 `json:"operations"`
	Vendor       uint32   `json:"-"`
}

func decodeDevice(b []byte) (Device, error) {
	r := reader{data: b}
	r.u16()
	vendor := r.u32()
	r.u16()
	r.str()
	r.u16()
	ops := r.u16s()
	for i := 0; i < 4; i++ {
		r.u16s()
	}
	d := Device{Manufacturer: r.str(), Model: r.str(), Firmware: r.str(), Vendor: vendor, Operations: ops}
	serial := r.str()
	if r.err != nil {
		return d, fmt.Errorf("invalid device info: %w", r.err)
	}
	if d.Model == "" || d.Firmware == "" {
		return d, errors.New("device did not provide model/firmware")
	}
	if serial != "" {
		sum := sha256.Sum256([]byte(d.Manufacturer + "\x00" + d.Model + "\x00" + serial))
		d.CameraID = hex.EncodeToString(sum[:])
	}
	return d, nil
}

type Asset struct {
	Name            string `json:"name"`
	Storage         uint32 `json:"storage"`
	Size            int64  `json:"size"`
	Kind            string `json:"kind"`
	Created         string `json:"created"`
	Representation  string `json:"representation"`
	handle, content uint32
	file            uint16
	createdMS       uint64
	listingLimit    int
	session         *Camera
}

func kind(name string) string {
	switch strings.ToLower(path.Ext(name)) {
	case ".arw":
		return "arw"
	case ".jpg", ".jpeg":
		return "jpeg"
	case ".hif", ".heif", ".heic":
		return "heif"
	default:
		return ""
	}
}
func decodeObject(b []byte) (Asset, error) {
	r := reader{data: b}
	a := Asset{Storage: r.u32(), Representation: "camera-object-unverified"}
	format := r.u16()
	r.u16()
	n := r.u32()
	a.Size = int64(n)
	if n == math.MaxUint32 {
		a.Size = -1
	}
	r.take(40)
	a.Name = r.str()
	a.Created = r.str()
	r.str()
	if r.err != nil {
		return a, fmt.Errorf("invalid object info: %w", r.err)
	}
	if format != 0x3001 {
		a.Kind = kind(a.Name)
	}
	return a, nil
}

func u32s(b []byte, max int) ([]uint32, error) {
	r := reader{data: b}
	n := r.u32()
	if uint64(n) > uint64(max) || uint64(n)*4 != uint64(len(r.data)) {
		return nil, errors.New("invalid or excessive object/storage count")
	}
	v := make([]uint32, n)
	for i := range v {
		v[i] = r.u32()
	}
	return v, r.err
}

func decodeContents(b []byte, slot uint32) ([]Asset, error) {
	r := reader{data: b}
	r.take(144)
	count := r.u32()
	if count > 100 {
		return nil, errors.New("Sony contents page exceeds 100 items")
	}
	var assets []Asset
	for i := uint32(0); i < count && r.err == nil; i++ {
		r.u32()
		id := r.u32()
		r.take(20)
		created := r.u64()
		r.take(24)
		r.take(12)
		marks := r.u32()
		if marks > 1<<20 {
			return nil, errors.New("excessive shot marks")
		}
		r.take(int(marks))
		files := r.u32()
		if files > 32 {
			return nil, errors.New("excessive files per Sony content")
		}
		for f := uint32(0); f < files && r.err == nil; f++ {
			fileID := r.u32()
			if fileID > math.MaxUint16 {
				return nil, errors.New("invalid Sony file id")
			}
			length := r.u32()
			if length == 0 || length > 4096 {
				return nil, errors.New("invalid Sony content path length")
			}
			name := r.take(int(length))
			if name == nil {
				break
			}
			if name[len(name)-1] != 0 || !utf8.Valid(name[:len(name)-1]) {
				return nil, errors.New("invalid Sony content path")
			}
			r.u32()
			size := r.u64()
			r.take(32)
			if size > math.MaxInt64 {
				return nil, errors.New("Sony file too large")
			}
			if r.u32() != 0 {
				r.take(8)
			}
			video := r.u32() != 0
			if video {
				r.take(76)
			}
			audio := r.u32() != 0
			if audio {
				r.take(16)
			}
			a := Asset{Name: path.Base(string(name[:len(name)-1])), Storage: slot, Size: int64(size), Created: fmt.Sprint(created), Representation: "camera-file-unverified", content: id, file: uint16(fileID), createdMS: created}
			if !video && !audio {
				a.Kind = kind(a.Name)
			}
			assets = append(assets, a)
		}
		// Preserve a pagination cursor even for content without downloadable stills.
		if files == 0 {
			assets = append(assets, Asset{content: id, createdMS: created})
		}
	}
	if r.err != nil {
		return nil, fmt.Errorf("invalid Sony content data: %w", r.err)
	}
	return assets, nil
}
