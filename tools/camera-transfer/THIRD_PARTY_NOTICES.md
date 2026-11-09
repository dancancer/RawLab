# Third-party notices

This experimental tool is part of RawLab and follows the repository license.
It does not include Sony SDK binaries, headers, example programs or restricted command-reference material.
Sony and Alpha are trademarks of Sony Group Corporation. This tool is not affiliated with or endorsed by Sony.

## alpha2go protocol reference

The PTP/IP packet layouts, Sony session sequence, contents-list layout and chunked content-read parameters
were studied from [alpha2go v0.3.0](https://github.com/Knallli/alpha2go/tree/02883425c9445c653b2950210187cdd1547320c2),
commit `02883425c9445c653b2950210187cdd1547320c2`, particularly `ptpip/{client,ops,proto,sonyremote,ssh}.go`.
RawLab implements its own bounded transaction receiver, parsers, command restrictions and persistent storage;
alpha2go is not a runtime dependency. The read-only implementation omits capture, settings and deletion APIs.

Attribution: alpha2go, Copyright 2026 The alpha2go Authors.
License: Apache License, Version 2.0; see [license text](licenses/alpha2go-LICENSE).

Upstream NOTICE:

```text
alpha2go
Copyright 2026 The alpha2go Authors

This product is licensed under the Apache License, Version 2.0 (see LICENSE).

The PTP/IP implementation follows the PTP (ISO 15740) and PTP/IP (CIPA
DC-005) specifications. The libgphoto2 project (LGPL-2.1) was consulted as a
reference for packet layouts and the publicly documented Sony vendor operation
codes; no libgphoto2 code is included.

This repository contains no code, headers or data from any Sony SDK.

Go dependencies: golang.org/x/crypto (BSD-3-Clause).

Sony and Alpha are trademarks of Sony Group Corporation. This project is not
affiliated with or endorsed by Sony.
```

## Go cryptography dependency

`golang.org/x/crypto v0.58.0`, package `ssh`, is pinned in `go.mod` and `go.sum`.
Copyright 2009 The Go Authors; BSD-3-Clause.
See [license text](licenses/golang-x-crypto-LICENSE) and
[upstream source](https://go.googlesource.com/crypto/).
Binary distributions must retain the applicable notices and license texts.

## CameraSync BLE protocol reference

The Android connection experiment studies CameraSync commit
[`c25814716a15afca997e0abf0a661974c5021669`](https://github.com/rock3r/CameraSync/tree/c25814716a15afca997e0abf0a661974c5021669),
particularly `docs/sony/DOWNLOAD_PICS.md`, `SonyProtocol.createPairingInit`,
and `SonyConnectionDelegate`'s MTU configuration. CameraSync is licensed under Apache-2.0.
The experiment independently implements these protocol steps with Android platform APIs;
CameraSync is not a runtime dependency. No GPS, date/time, shutter or power-off commands are included.

SonyCameraKit was inspected as a research lead. Its unlicensed source was not copied into this tool.
