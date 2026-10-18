# RawLab 0.8.1 共享文案迁移记录

## 范围与基线

工作分支 `feature/shared-copy-source`，基线 `c74e3ea`。
只迁移四端六语原生词条，新增来源、纯 Python 工具、检查和必要说明。
没有改 Swift、Kotlin、C#、构建系统、CI 策略或任何原始译文，没有删键。
没有联网、push、部署或操作其他 worktree。

来源与占位符规则见 [README](README.md)。共享条目按 Mac → iOS → Windows →
Android 取第一份原值；格式归一化不参与翻译改写。

## 数量

| 项目 | Mac | iOS | Windows | Android |
| --- | ---: | ---: | ---: | ---: |
| 原生键数，每语言 | 500 | 392 | 500 | 348 |
| 平台特有原文数 | 198 | 133 | 221 | 134 |
| 平台覆盖数 | 0 | 0 | 4 | 2 |

共享原文共 346 条。一个来源可对应同端多个原生键或资源名，所以特有原文数不等于
原生键数。Windows 有两个仅数字精度不同的摘要键，保留各自完整格式，文字共享一条
特有来源；其六语原文归一化后完全相同。

## 六项平台覆盖

每项六语值均完整保留该平台基线原值，没有自行润色。

| 平台 | 原文 | 保留理由与调用依据 |
| --- | --- | --- |
| Android | 从文件导入 | 系统 `OpenDocument` 不是 Apple Files 应用，保留通用 files/fichiers/archivos；`MainActivity.kt:107`，iOS 对照 `ContentView+Helpers.swift:318`。 |
| Android | 照片图库 | 保存至 MediaStore/Pictures/RawLab，而不是 iOS Photos 应用；`PhotoStorage.kt:179`、`BatchExportModel.kt:189`。 |
| Windows | 尚未选择 RAW | 活动旧键用于同时接受 RAW 与普通图像的批量选择空状态，保留 generic photo；`BatchExportWindow.xaml:46`、`BatchExportWindow.xaml.cs:139`。 |
| Windows | 打开 RAW | 活动旧键用于主菜单、工具栏和空状态入口，实际文件选择器接受 RAW 与普通图像，保留 generic photo；`MainWindow.xaml:8`、`MainWindow.xaml.cs:592`。 |
| Windows | 添加 RAW | 活动旧键用于批量添加按钮，实际选择器接受 RAW 与普通图像，保留 generic photos；`BatchExportWindow.xaml:9`、`BatchExportWindow.xaml.cs:139`。 |
| Windows | 照片 | 目录树 `PhotoGroup` 是照片集合标题，保留复数；Mac 同键是单张照片名的后备标题；`FileLibrary.cs:66`、`EditorView.swift:205`。 |

Windows 三项 RAW 旧键的名称与该端实际功能已有偏差，本次不改代码，仅保留原本正确的
照片说法。普通术语、句式和大小写差异不设覆盖。`确定` 的 Confirm/OK 差异没有充分的
平台专属证据，按合并规则统一。Finder、资源管理器、右键和平台版本提示的中文键本来
不同，保留在各自 `unique`，不创建冗余覆盖。

## 值变化

以下比较解析后的原生值，不计排序、注释、缩进、XML 外层保空白引号等编码变化。
完整逐项清单由 `audit.py` 写入任务报告目录的 `value-changes.tsv`。

| 平台 | zh-Hans | en | de | fr | ja | es |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Mac | 0 | 0 | 0 | 0 | 0 | 0 |
| iOS | 0 | 14 | 15 | 7 | 11 | 6 |
| Windows | 0 | 73 | 50 | 46 | 50 | 38 |
| Android | 1 | 68 | 45 | 50 | 48 | 35 |

合计 557 项原生值变化，其中 556 项为机械统一译文，1 项仅为 Android 中文
`message_exposure_ev` 从 `%+.2f` 改为位置参数 `%1$+.2f`，类型、精度和显示不变。
Mac 六语译文全部零变化。

## 键集合与 Android 反查

`audit.py` 对照基线独立解析 30 个原生文件：每个文件键集合完全一致，增加 0、删除 0。
Android 资源名、所在文件及参数类型/符号/精度保持不变。死键删除清单为空。
所有共享、特有和覆盖译文均通过基线取值优先级/原值校验。

`android-reverse-lookup.tsv` 是完整问题清单，包含中文原文、所有资源名和其他端的
精确对应键，没有按近义词或资源名猜测：

- 134 个资源在其他端没有精确中文对应，全部保留为 Android 特有原文。
- 20 组中文对应多个 Android 资源名，所有资源名保留并映射到同一明确原文。
  其中 19 组有 Mac 基准，像素输入范围提示一组取 iOS；没有任意挑选 Android 译文。
- 这 20 组为：S 曲线、亮度降噪、取消、对比度、强度、曝光、水平翻转、白平衡、胶片、
  自动、自定义、色彩降噪、色温、色调、请输入 1–65535 之间的像素数、锐化、阴影、降噪、
  饱和度、高光。没有无法确定中文原文而猜测映射的资源。

## 验证

本地 Python 测试设置 `PYTHONDONTWRITEBYTECODE=1`，临时文件统一通过 `TMPDIR`
放入任务报告目录。以下是实际结果，不代表 hosted CI 或设备验收通过。

| 命令或检查 | 结果 |
| --- | --- |
| 生成器尚不存在时运行新增 `--check` 测试 | FAIL，子进程退出 2：`can't open file .../scripts/localization/generate.py`；先提交失败测试，再实现。 |
| 两项补充格式回归：.NET 字面花括号/对齐、同参数冲突格式 | 先观察到 2 FAIL，修复解析器后通过。 |
| `python3 scripts/localization/generate.py --check` | PASS，30 文件逐字节一致，无游离资源。 |
| `python3 tests/test_localization.py` | PASS，22 tests。 |
| `python3 tests/test_localization.py GeneratorFormatTests GeneratorSourceTests` | PASS，10 tests，已接入 Linux CI；不调用 plutil。 |
| `python3 -m unittest discover -s tests -p 'test*.py'` | PASS，22 tests，覆盖完整根 tests 目录。 |
| `python3 RawLabMac/tests/test_interface_copy.py` | PASS，11 tests。 |
| `bash RawLab/tests/catalog-terms.sh` | FAIL，下面列出的 3 项 Mac 基准冲突；不改译文或放宽检查。 |
| Windows `dotnet run --project LocalizationChecks.csproj -c Release -p:EnableWindowsTargeting=true` | PASS，检查 275 处静态 Loc 调用及六语嵌入资源。 |
| `rg --files RawLabMac RawLab -g '*.strings' -0 \| xargs -0 plutil -lint` | PASS，全部 18 个 .strings，包含未改的 InfoPlist。 |
| `python3 scripts/ci/test_workflow.py` | PASS，8 tests，CI 策略无需修改。 |
| Android Gradle `:app:mergeDebugResources :app:testDebugUnitTest` | NOT REACHED，Gradle daemon 启动时 `java.net.SocketException: Operation not permitted`。 |
| Android AAPT2 35 compile 全部 res | PASS。 |
| Android AAPT2 35 对 12 个词条文件 compile/link/dump | PASS；348 × 6 = 2088 个编译后运行时字符串逐项等于来源渲染值。 |
| `audit.py --base c74e3ea --output <报告目录>` | PASS，键集合、格式、中文反查、取值优先级及覆盖原值均自证。 |
| `git diff --check` | PASS。 |

Windows 使用 `/Users/xupeng/mycode/rawtools/build/tools/dotnet/dotnet`，在
`RawLabWindows/tests/localization` 执行。为遵守离线要求，`RestoreConfigFile` 指向仅含
`<packageSources><clear /></packageSources>` 的临时配置，`NUGET_PACKAGES` 显式指向
现有本机缓存。第一次私有 CLI home 未指定缓存时出现 NU1100，明确缓存后按原命令
通过；另一次关闭 Windows targeting 的纯 .NET 8 补充运行也通过。
运行时有 `CSSM_ModuleLoad()` 环境警告，但最终退出 0。没有下载依赖。

Android 实际尝试命令如下，根目录没有 `gradlew`，因此使用 Android 的 wrapper：

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 21) ANDROID_HOME=$HOME/Library/Android/sdk \
ANDROID_USER_HOME=<报告目录>/android-user TMPDIR=<报告目录> \
./RawLabAndroid/gradlew -p RawLabAndroid --offline --no-daemon \
  --project-cache-dir <报告目录>/gradle-project -Pandroid.builder.sdkDownload=false \
  :app:mergeDebugResources :app:testDebugUnitTest
```

没有请求联网、绕过沙箱或修改 Kotlin 来解决 Gradle 环境问题。AAPT2 补充验证不是
Gradle unit test 的替代结论。验证后清理本任务的 bin/obj、临时脚本、测试包和缓存；
保留要求交付的四份审计报告。

## 待协调冲突与风险

这三项都由按要求采用 Mac 原值触发，不是平台差异，不为它们创建覆盖：

1. iOS 西语 `色调`、`色相` 均为 `Matiz`，违反 `catalog-terms.sh:25` 的区分要求。
2. iOS 德语 `正在导出` 为 `Exportieren`，违反 `catalog-terms.sh:29` 的 wird/werden 要求。
3. iOS 英文 `重置降噪` 为 `Reset noise reduction`；`重置%@` + `降噪` 得到
   `Reset Noise Reduction`，违反 `catalog-terms.sh:34` 的完全相等要求。

需协调者决定修改文案基准还是检查契约。本任务不擅自选择译法。
Android Gradle 资源合并和单元测试仍需在允许本地套接字的环境重跑；没有设备/UI验收。
整体不是全绿验收，不能将上述冲突或未执行的平台检查表述为通过。
