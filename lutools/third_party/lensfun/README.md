# Lensfun Dependency and Database

RawLab uses the unmodified Lensfun 0.3.4 library. The macOS dependency builder pins
its source archive by SHA-256; generated library/source build artifacts are not
part of this directory.

`version_1/` is an unmodified offline snapshot downloaded on 2026-10-12 from
https://lensfun.github.io/db/version_1.tar.bz2. Archive SHA-256:
`97c9f8059accae0128a413bc610a04a4548e8da2764a6d3d60d82bf917639457`.
It is compatible with stable Lensfun's maximum database version 1. Database
updates are explicit source changes, not downloads during rendering.

Library authors and license information are retained in `UPSTREAM-README.md`
and the accompanying license texts. See https://lensfun.github.io/ for the
database project, contributors and calibration submission process.
