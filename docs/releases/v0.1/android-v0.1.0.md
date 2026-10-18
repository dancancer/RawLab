# RawLab Android v0.1.0

首个原生 Android 版本，提供 RAW 显影、富士胶片 LUT 和竖屏照片编辑。

## 下载与安装

- `RawLab-Android-0.1.0.apk`：专用发布密钥签名的通用 APK，包含 ARM64 和 x86_64。
- `SHA256SUMS`：发布附件的 SHA-256 校验值。
- `LibRaw-0.21.5-source.tar.gz`：实际使用的 LibRaw 官方源代码归档，构建配方位于本标签的 `RawLabAndroid/`。
- 要求 Android 8.0 / API 26 或更高版本。通过 GitHub 下载并安装，不是应用商店版本。
- 已安装本地 debug 版时，因签名不同无法覆盖安装。先导出并保存编辑结果，再自行卸载 debug 版、安装此包；卸载会删除应用私有数据，不会删除相册原图。

发布签名证书 SHA-256：

```text
9fd68e245a597cde2abb949ff807819a89afdd4b000b5ad02391181f38a06048
```

## 功能

- 应用内 RAW 相册与相册筛选，支持 Android 14+ 部分照片授权；拒绝权限后仍可从系统文件入口导入。
- 十种内置胶片、中性/结果滑动对比、曝光、胶片强度、色温和色调调整。
- 竖屏大画面、可收起的底部调节区、固定工具行；色温和色调独立操作。
- GLES 3.1 加速缩放、色彩转换、LUT 和逐像素明暗处理，不可用时自动回退 CPU。
- 原尺寸 JPEG / 16-bit PNG 导出到相册或文件，不覆盖 RAW 原图。
- 修复 debug 构建中 LibRaw 未优化导致的色温调整延迟；画面不显示 GPU/耗时角标。

## 验证与限制

- Release APK 签名校验通过，`debuggable=false`；两种 ABI 的 8 个原生库均通过 16 KB 对齐检查。
- 正式签名 APK 在 Android 15 ARM64 模拟器完成 4 项 RAW/存储测试，包括 7008x4672 原尺寸 JPEG 和 16-bit PNG 导出。
- Lenovo TB320FC / Adreno 730 真机的同源 debug 版本通过 8 项测试，覆盖 GPU 切换、RAW 导出、竖屏操作和白平衡性能；未用正式签名包替换真机现有 debug 安装。
- Debug/Release 单元测试各 8 项、共享 C++ 回归 6 项以及真实 RAW 的 CPU/Metal 回归通过。Release lint 为 0 错误、12 个警告。仓库当前没有远程 CI 工作流，以上为本地验证。
- RAW 解包、白平衡、去马赛克和文件编码仍在 CPU。精确白平衡调整仍有等待时间，不宣称全流程 GPU 解码。
- 全尺寸 RAW 需要较多内存。没有覆盖所有相机、GPU、Android 版本或 16 KB 页大小真机。
- 只编辑 RAW，不是 JPEG/HEIC 编辑器；编辑参数不跨进程退出保存。
- 相册只展示已授权且被系统收录的 RAW，其他文件通过系统文件选择器导入。
- 这是独立项目，不是 Fujifilm 官方应用，胶片效果不保证与相机 JPEG 完全一致。

详细颜色约定、构建方式与性能测量见仓库的 `RawLabAndroid/README.md`、`RawLabAndroid/gpu-verification.md` 和 `lutools/docs/color-contract.md`。
