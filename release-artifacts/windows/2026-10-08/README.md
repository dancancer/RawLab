# Windows 发布交接 · 2026-10-08

已验证的 Windows 10/11 x64 独立运行包，供 Mac 端统一发布。源码提交为 `a24d84036bc17e9b4a7c3ea3e795037d8ebe6e01`，代码与产物均已并入 `codex/cross-platform-photo-zoom` 分支。此目录只提供发布附件，没有创建 GitHub Release 或 tag。

包名为 `RawLab-Windows-interaction-20261008-win-x64.zip`，包含 .NET 8 Desktop Runtime、Visual C++ / OpenMP 运行库、LibRaw、LUT、ExifTool 及许可证。程序未签名，程序集版本仍为 `0.2.0`；日期标识用于本次交接，不代表已经发布新的正式版本。

## 在 Mac 上恢复并校验

ZIP 按最多 64 MiB 分为两个二进制片段，直接随 Git 保存，无需 Git LFS。它们是同一个 ZIP 的字节分片，不能分别解压。从仓库根目录执行：

```sh
cd release-artifacts/windows/2026-10-08
shasum -a 256 -c SHA256SUMS.parts.txt &&
cat RawLab-Windows-interaction-20261008-win-x64.zip.part01 \
    RawLab-Windows-interaction-20261008-win-x64.zip.part02 \
    > RawLab-Windows-interaction-20261008-win-x64.zip &&
shasum -a 256 -c SHA256SUMS.txt &&
unzip -t RawLab-Windows-interaction-20261008-win-x64.zip
```

校验通过后，将恢复的完整 ZIP 和 `SHA256SUMS.txt` 用作发布附件；分片仅用于仓库传输。Windows 用户解压后运行 `RawLab-Windows/RawLab.exe`，保留整个目录即可。Mac 只能恢复、校验和上传该 Windows 包，不能直接运行程序。

## 内容与验证

- 本包含快速内嵌预览、多核 RAW 处理、原尺寸图像缓存、复用绘制图层的平移，以及远程桌面下的 WPF 硬件加速。
- 已通过 119 项 Windows 检查，38 组 Sony/DJI 输出像素哈希保持一致；共享核心此前 11 项 CTest 通过。实际窗口已检查双击放大和两侧同步拖动。
- 使用上一轮已验证的程序二进制，更新随包 README 和构建来源；没有改变运行代码。打包后校验分片重组 SHA-256，并逐个校验 ZIP 内文件与待打包目录一致。
- 不含用户 RAW 样片、测试截图或本地测试日志；ExifTool 官方发行目录自带的小型测试资源保持完整。
- `manifest.json` 记录源码提交、完整包与分片的长度和 SHA-256；包内 `build-info.json` 记录来源及验证摘要。构建时的分支名称作为历史来源保留，拉取和发布请使用 `codex/cross-platform-photo-zoom`；迁移分支未改变包内容或校验值。

详细行为和测试边界见 [Windows README](../../../RawLabWindows/README.md) 与 [性能记录](../../../RawLabWindows/performance.md)。
