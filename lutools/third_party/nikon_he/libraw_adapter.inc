// SPDX-License-Identifier: LGPL-2.1
// Copyright 2026 RawLab contributors.
// Included after dcraw_defs.h and codec.h in LibRaw's decoder translation unit.
#include <algorithm>
void LibRaw::nikon_he_load_raw()
{
    if (dng_version || tiff_bps != 14 || !raw_image ||
        (imgdata.makernotes.nikon.NEFCompression != 13 &&
         imgdata.makernotes.nikon.NEFCompression != 14) ||
        FC(0, 0) != 0 || FC(0, 1) != 1 || FC(1, 1) != 2 ||
        (FC(1, 0) != 1 && FC(1, 0) != 3))
        throw LIBRAW_EXCEPTION_UNSUPPORTED_FORMAT;
    const INT64 length = data_size;
    const INT64 offset = data_offset;
    const INT64 file_size = ifp->size();
    if (offset < 0 || offset > file_size || length <= 0 || length > file_size - offset)
        throw LIBRAW_EXCEPTION_DECODE_RAW;
    const uint64_t samples = uint64_t(raw_width) * raw_height;
    const uint64_t budget = uint64_t(imgdata.rawparams.max_raw_memory_mb) * 1024 * 1024;
    // 为传感器存储、wavelet 平面、重建和压缩输入预留内存。
    if (samples > budget / 16 || uint64_t(length) > budget - 16 * samples)
        throw LIBRAW_EXCEPTION_ALLOC;
    std::vector<uint8_t> stream(static_cast<size_t>(length));
    if (ifp->seek(offset, SEEK_SET) || ifp->read(stream.data(), 1, stream.size()) != stream.size())
        throw LIBRAW_EXCEPTION_IO_CORRUPT;
    checkCancel();
    try
    {
        const auto mosaic = rawlab::nikon_he::decode(stream.data(), stream.size(), raw_width, raw_height);
        checkCancel();
        std::copy(mosaic.begin(), mosaic.end(), raw_image);
        maximum = 16383;
    }
    catch (const rawlab::nikon_he::UnsupportedError &)
    {
        throw LIBRAW_EXCEPTION_UNSUPPORTED_FORMAT;
    }
    catch (const rawlab::nikon_he::DecodeError &)
    {
        throw LIBRAW_EXCEPTION_DECODE_RAW;
    }
}
