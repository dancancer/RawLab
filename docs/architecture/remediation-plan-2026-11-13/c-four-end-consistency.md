> 返回索引：[RawLab 综合整改任务清单](../remediation-plan-2026-11-13.md)

# C. 四端一致性专项（主 §14.8 × 复审 × 0cf4a88a）

✅ 一致或已修；❌ 仍有问题；⏳ 在飞；— 不适用。

| 规则 | Mac（参考端） | iOS | Android | Windows | 结论 |
|---|---|---|---|---|---|
| 普通图片粘到 RAW：曝光基准占位 | ✅ #250 `MacAdjustmentTransfer.swift:159` | ✅ #250 `IOSAdjustmentTransfer.swift:136` | ❌ `AdjustmentTransfer.kt:131-134` | ✅ #255 `AdjustmentTransfer.cs:116` | **Android 偏离**（A18） |
| 同上：白平衡占位（none/null 当成相机白平衡） | ⏳ `MacAdjustmentTransferWB.swift:140` | ⏳ `IOSAdjustmentTransferWB.swift:125` | ❌ `AdjustmentTransferWB.kt:26` | ✅ #255 `AdjustmentTransferWB.cs:68` | Mac/iOS 在飞；Android 还没开始 |
| 同上：“全部”范围时镜头五项被关掉 | ⏳ `MacAdjustmentTransferValues.swift:102-107` | ⏳ `IOSAdjustmentTransferValues.swift:74-79` | ❌ `AdjustmentTransferValues.kt:95-98,132-137` | ❌ `AdjustmentTransferValues.cs:78-80,110-118` | **四端都还不一致**；只有 Mac/iOS 在飞 |
| 同上：默认范围时 RAW 降噪被清零 | ⏳ `:93,116-121` | ⏳ `:63-64,85-88` | —（两个键恒为 0） | —（两个键恒为 0） | 在飞 PR 修完即对齐 |
| RAW 降噪的交换字段（`raw_level` 还是 `post_rgb`） | 写 raw_level，拒收非 0 的 post_rgb（`:93-94,113-114`） | 反过来（`:63-64,84-86`） | 两个都写 0，非 0 拒收（`:82,105`） | 同 Android（`:72,87`） | **语义分叉，要先决定（Q3）**，在飞 PR 不解决这个 |
| 带配方的普通照片粘到 HDR 时按强度换算 | ✅ #250 `Shared/HDRAdjustmentTransfer.swift:107` | ✅（共用 Shared） | ❌ `AdjustmentTransfer.kt:220-243` | ✅ #255 `HDRAdjustmentTransfer.cs:80` | **Android 偏离**（A17） |
| 普通模式“重置全部”保留未启用的 HDR | ✅ 参考行为 | ✅ #256 | ✅ #253 | ✅ #255（经 `Defaults(edit)`；`HDRChecks.cs:134-158`） | **已对齐**；Windows 的 `Adjustments.ResetAll()` 是死路径，见 L2 |
| HDR 显示映射和相机显影的重置入口 | 有渲染重置（`Shared/Native/HDRMonitoring.swift:56`，#256） | ✅ #256、#262 | #253 补了 HDR 区块的重置按钮（只看了 diff 规模，没细读） | ✅ #255（`MainWindow.HDR.cs:308,401`） | 基本对齐；主 §14.6.1d 的“分组重置不清 FBDD”等细项没复核 |
| 粘贴时比较处理版本 | ❌ `Shared/AdjustmentTransfer.swift:422` 只校验范围 | ❌ 同上 | ❌ | ❌ | **四端一致地缺这条规则**，要先决定（Q4） |
| 预设库、外观库逐条容错 | ❌ `Shared/AdjustmentPresetStore.swift:170-180`（M9 只是把它纳入更新门禁） | ❌ 同上 | ❌ `AdjustmentPresetStore.kt:108-130` | ✅ #251 | 以 Windows 为参照移植 |
| 重置入口七种范围 | ✅ | ✅ #262 | 没核对 | 没核对 | 覆盖缺口（E.2） |
| 相机：坏文件卡住、张数上限 | — | ✅ #258（联机上限见 I-N6） | ✅ #257 | — | 已对齐 |
| 相机：重连后认上次进度 | — | ✅ #267（三段抽样） | ❌ A12 | — | **Android 偏离**；建议照搬 iOS 方案（Q7） |

**整改顺序**

1. **在飞 PR 合入**：Mac/iOS 的白平衡、镜头、旧版降噪占位，加上 `adjustment-transfer-scenarios-v1.json` 和契约文档。这是后面所有移植的“规则源”。
2. **Android 一个 PR**：A18（曝光基准）、白平衡、镜头占位、A17（HDR 配方强度），全部用共享场景向量驱动。Android 的 80 条硬编码计数（主 §14.7.1c）一并改成读文件长度。
3. **Windows 一个小 PR**：只改镜头占位，跑场景向量。
4. **产品决策 Q3、Q4 之后**：`raw_level`/`post_rgb` 语义和处理版本比较写进场景向量，再四端各改一次。
5. **预设库、外观库逐条容错**：Mac/iOS 一个 Shared PR，Android 一个 PR，都以 Windows 的 `ListUnreadable` 为参照。
