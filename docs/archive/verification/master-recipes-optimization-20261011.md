# 大师配方参考辅助优化

日期：2026-10-11。范围：旧快照 `b175b2837c3fe8661bd5b34eed49cfe07b647b8a` 的隔离修复工作树，macOS，全部 14 个配方。优化期间未提交或推送；后续用户已授权向 `development` 提交 PR 并合并。原工作区、NAS 原图、原始 RAW、已有模型代码和 checkpoint 均未修改。

本文保留此前 LUT 优化及 PR #19 的验收记录。后续显式 HSL 配方参数、整体缩放和参考校准见 [HSL 配方校准](master-recipes-hsl-20261011.md)；下文“配方不覆盖 HSL”仅描述此前版本。

## 方法与来源

- 按用户本次指定使用 `master/color-grading-masters` 的 13 组、703 张成片参考，以及既有批准 manifest 中滨田的明亮日光组。没有真实同内容 before/after 配对。
- 最终保留新增 13 组的 616 张参考、滨田的 100 张参考。合计排除 58 张重复代理、22 张黑白图及 8 张不支持的 ICC 图；没有把坏 ICC 当 sRGB 强行使用。
- 716 张保留参考中，399 张经 embedded ICC 转为 sRGB，317 张无 ICC，显式记录为假定 sRGB。包含 Adobe RGB、ProPhoto RGB 和 Display P3 的素材不能直接按原数值当 sRGB。
- 滨田按已有 `source_id` 系列切分；其他 616 张未提供系列/场景 ID、未保留可用拍摄日，只有代理去重后的图像切分。因此不声称已经排除同拍摄组/不同裁切之间的泄漏，也不称独立风格准确率评测。
- `.9` 使用已有 PyTorch `2.9.0+cu128`、Pillow `11.1.0`、NumPy `1.26.4` 和单张空闲 Tesla T10。GPU 0 按 UUID 固定；既有 GPU 3 服务未终止，系统包、驱动和环境未升级。
- CanonCGT 源版本 `229a7d3ec24af19ea5d97bb136f0317762bb9261`；SSL checkpoint SHA-256 `5630c6dd5ceefa0d36d69ad298a5b87f1260dd02620a60af84cb4e259b4ad362`，实际 `strict=True` 加载。
- 现有 SetLUT 的训练只覆盖五个合成函数，本轮没有把它冒称真实摄影师风格模型。采用 CanonCGT canonicalization 的伪输入/原参考辅助拟合，并以原 CUBE 为强先验；不把模型伪配对称为真实调色真值。

每个风格最多 300 步，拟合 9-grid 的小修正；灰轴/肤色探针及原表约束限制风格漂移。训练和验证均经过同一范围与灰轴处理。新表固定为 65-grid、display-sRGB/BT.709、`referenceStyle`。不读取或再烘焙六个 UI 控件，不做逐 RAW 自适应预测。

源码和复现命令见 `experiments/master-recipes-v2/README.md`。私有服务器运行目录为 `rawlab-hamada/runs/master-recipes-v2-20261011`；13 条最终产物来自 `candidates-final`，酒井最终来自随后单独重算的 `sakai-smoothed`。后续新增的诊断字段、权限来源记录和 65-grid 拒绝门禁没有改变其他 13 条表的数学变换；没有因这些元数据变化重复推理。旧 LUT 备份、参考清单、排除原因、四栏伪输入预览和训练历史保留在私有 run，不打包照片或模型权重。

## 测量结果

- 14/14 新 CUBE 的结构、finite、范围和样本数量通过 `generate-lut` 校验；均为 65³、274625 行样本。
- 用同一个 validator 的内部通道截断定义，滨田/酒井/Luiz 的旧值 `3.60% / 3.27% / 1.36%` 均降为 `0%`；其余新表也是 `0%`。这是 LUT 网格诊断，不表示所有 RAW 的高光都已恢复，也不代表后续 UI 曝光不会导致裁切。
- 酒井对相邻节点大于 `0.030` 的亮度下降从 `5053/811200` 降为 `2227/811200`，约 `0.623% -> 0.275%`。采用一次小核残差平滑，没有强制所有 RGB 单通道方向都亮度单调，因为改变一个原色也会改变色相。
- 14 条新表的灰轴亮度均无反转。全表平均 RGB 改变量为 `0.001409..0.004603`；最大单点改变量 `0.050873`；最大灰轴相对旧版改变量 `0.014414`，均在预设的风格保留预算内。
- 验证伪目标损失下降约 `3.6%..28.2%`，未参与选表的 test 图像诊断下降约 `5.1%..29.6%`。这些数值只度量 CanonCGT 伪目标，不是摄影师风格复现准确率。
- Python 冻结 LUT 到 CUBE 的有限采样表示误差通过 `<=0.02` 门禁。实际写入的 CUBE 又经独立 validator 和原生渲染重放验证；不以 Python 导出状态代替原生验收。

| 配方 | 保留参考 | train/val/test | 选用 step |
| --- | ---: | --- | ---: |
| 滨田英明 | 100 | 59/23/18 | 150 |
| 保井崇志 | 50 | 30/10/10 | 300 |
| 酒井贵弘 | 49 | 31/9/9 | 150 |
| withluke | 41 | 25/8/8 | 300 |
| Daniel Casson | 51 | 31/10/10 | 300 |
| Billy Dinh | 48 | 30/9/9 | 250 |
| rkrkrk | 52 | 32/10/10 | 250 |
| Samalive | 35 | 21/7/7 | 250 |
| Iwona | 47 | 29/9/9 | 250 |
| CineStill 800T | 30 | 18/6/6 | 250 |
| Wilson Lee | 49 | 31/9/9 | 100 |
| Luiz Clas | 56 | 34/11/11 | 150 |
| Ivan Ivanchenko | 55 | 33/11/11 | 50 |
| Jungraphy | 53 | 33/10/10 | 300 |

## 已通过检查

- 8 个实验单元测试：修正幅度/梯度、范围与灰轴、非对称轴序往返、ICC/无 ICC/坏 ICC、分组不跨 split、无合格候选拒绝、灰轴反转导出拒绝、残差平滑。范围修复、导出拒绝和平滑均先观察到针对旧行为的失败，再通过新实现。
- `bash RawLabMac/tests/master-recipe.sh`：14 条 ID/资源/图片、预设覆盖六控件、0/50/100/200% 参数缩放和持久化。
- `bash RawLabMac/tests/edit-model.sh`：实际 EditorModel 选择、胶片互斥、保存/恢复及手动覆盖。
- `bash RawLabMac/tests/master-recipe-render.sh <DJI DNG> <Sony ARW>`：全部 14 条、两种真实 RAW、四档强度；与显式手动参数一致，0% 完全中性，CPU/Force Metal 在 2 DN 门限内，拍摄白平衡/自定义色温/最大 tint 正常，单张与冻结批量的 16-bit PNG/JPEG 解码像素一致，14 个结果不重复，原 RAW 未修改。
- `ctest --test-dir lutools/build-macos --output-on-failure`：当前配置 14/14。
- `bash RawLabMac/build.sh` 和 `bash RawLabMac/tests/bundle.sh`：构建、打包、签名、动态依赖及全部 CUBE/PNG 与源资产逐文件比对。

## 视觉与限制

本轮是保留原有风格的有限校准，不是大幅换色。查看了 14 条在同一 DJI 山景及 Sony 街景上的实际原生输出，以及人像、童话、城市和夜景参考的四栏伪输入对照；未见新空白、破图、灾难性肤色破坏或明显新色带。新旧图在多数场景下接近，不能据此声称大幅可见改善。

滨田仍会把部分深蓝衣物推向天青，酒井仍偏明亮、浅淡粉白，这是旧版风格及全局 RGB 映射的保留结果。普通 LUT 无法可靠区分同 RGB 的蓝衣与蓝天，亦不产生 halation、局部补光、散景或颗粒。CineStill/RK 等不能凭一张日间伪输入判断夜景复现；本轮没有专用真实夜景 RAW，其他平台 GPU 也未运行。

Billy、CineStill、Jungraphy、RK、Samalive 的灰轴颜色仍触发通用偏色提示，作为原有创意分级保留，不把它们称作严格 validator 全部无警告。

实际 RAW 总览：忽略目录 `build/master-optimization/master-recipes-v2-dji.png`、`master-recipes-v2-sony.png`；旧/新版四配方对照：`master-recipes-v2-comparison.png`。这些是本地检查产物，不提交。界面的图片/名称/弱说明、无外框、左右滚动按钮，以及预设覆盖和整体强度规则均保持上一轮实现。

## 交付前兼容修复

交付复核补充了旧配方记录的单次迁移：无版本标记的旧 `Adjustments` 合入六个预设默认值，将旧绝对 tint 转为拍摄白平衡相对偏移；新记录带 `masterRecipeSettingsVersion=2`，再次打开不重复合入。单张编辑及旧的未完成批量任务使用同一解码迁移。迁移后统一采用用户确认的整体强度规则，不保留旧版“只缩放隐藏 delta”的算法。

白平衡缓存键增加文件 inode。原生 RAWProcessor 仍按路径/大小/mtime 缓存，故同路径 inode 更换时，Mac wrapper 同时重建 native session 并保留 GPU mode。回归在临时副本上将 DNG 替换为等长、同 mtime 的 Sony RAW；更新后的像素和 WB 必须与 fresh engine 一致，两个原始 fixture 不修改。

缓存属性读取失败时交回原生处理，保留原有 `RenderError` 错误映射，不向 UI 泄露 Foundation 文件错误。缺失 RAW、同身份字段替换、旧编辑记录及旧批量记录均有针对性回归。

PR 的无照片 UI 截图来自隔离程序中的生产 `FilmDock` 和 `MasterRecipeDock`，而非完整编辑器截图。上方为溢出列表，下方包含可完全容纳的胶片列表及紧凑配方列表；按钮行属于验证程序。

![Native selector verification](../../screenshots/master-recipe-pickers.png)

## 与 development 整合

交付时目标分支已更新至 `17cc79dd85b662213459d6b77be9cdb73b96de0a`，包含 PR #18 的 HSL 和自动曝光。隔离分支合入该版本，保留新照片/输入重置的 `preview` 默认、缺少曝光字段的旧记录继续使用 `scene`，并将 HSL 的可选解码、合法性检查与配方单次迁移合并。配方不覆盖 HSL，自动曝光仍作为当前曝光控制值参与用户确认的整体强度缩放。

Metal 主机与 shader 同步保留 display-sRGB 输入标记及 HSL 数组，参数大小 `288`、HSL 数组偏移 `192`；GLES/D3D11 的 HSL 签名和 sRGB Auto CPU 回退保留。共享 C request v2 未变化。iOS/Android/Windows/Shared 相对目标分支无新增差异，本轮不重复声称其平台硬件验收。

整合后构建及 bundle 检查通过，CTest 为 `15/15`。`master-recipe.sh`、`adjustments.sh`（DJI DNG）、`edit-model.sh`、`edit-memory.sh`、`batch-export.sh`、`horizontal-picker.sh` 均重新通过。旧配方与独立 HSL 同时保存/迁移，以及两种 RAW 的 display-sRGB 配方叠加 HSL、冷 WB primer 后恢复 HSL、下一次中性渲染清除 HSL 均有回归覆盖。

整合后的 `master-recipe-render.sh <DJI DNG> <Sony ARW>` 完整矩阵通过：14 配方、四档强度、CPU/强制 Metal、单张/冻结批量 JPEG 与 16-bit PNG 像素对照；包含上述 HSL、缺失输入和 inode 更换回归。两个原始 RAW 的身份信息未变化。
