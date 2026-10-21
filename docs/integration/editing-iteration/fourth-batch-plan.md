# 第四批：S2a 原生六组导航与生产重置入口

第三批 #115–#118 已合入 `development@1031745c`，联合 CI [39617993292](https://github.com/dancancer/RawLab/actions/runs/39617993292) 全部通过。本批从更新后的 `development@0fd52624648f5473364b78e6cfb28cf7c471be17` 开始，保留随后合入的 #106 处理版本契约；该新基线 CI 独立跟踪，不把此前 CI 当作新基线的证据。

## 交付范围

以已合入的 `docs/design/editor-workspace/requirements.md` REQ-01/02/05/06/07 和技术方案 3/4/6/10 为依据，沿现有原生 Operate 界面落地六组常驻导航、默认工具、组内路由、完整改动标记、生产 reset 菜单/确认与固定面板预算。S2a 是 S2 的第一部分，不标记整个 ITER-02 或 S2 完成。

本批同时交付 current-tool 候选 scope（Mac/iOS/Windows 尚缺）、HSL session channel、几何/镜头单工具与整组成对 reset、全量 reset 的两阶段草稿解决流程。HSL 三轴单行布局/方向轨道、精确值/单值重置/fine、iOS 刻度窗口属于 S2b；对比/纯预览/信息/留白/细进度线属于 S3；移动 RGB 桥接与联合全流程属于 S4。现有单值输入不变，但保留的“本工具/HSL”旧按钮须转到同一 scope，不能绕过新候选。

## 共同决定

- 六组 ID 顺序固定 looks/light/color/effects/detail/geometry，标题分别外观/光线/颜色/效果/细节/几何与镜头；默认工具 film/exposure/WB/vignette/denoise/geometry。一张本端描述表提供 groupFor/tools/defaultTool，旧参数枚举或翻译字符串不充当组 ID。
- 组、工具、HSL channel、展开状态属于 UI session，不进入存储格式。导航本身零保存；进入/离开几何草稿允许既有 uncropped/committed 恢复预览，不能把必要预览误报为额外编辑。
- 标记与菜单 NoChange 使用原生 S1 完整逻辑快照/有效默认，不能复用旧 scalar progress 聚合代替；busy 只影响动作可用性，不能令已改动事实消失。保留 recipe contributions、strength=0、关闭的辅助对象、RAW/raster 与显式身份语义。
- 普通工具重置只改该工具全部字段；WB、暗角/颗粒和降噪是完整对象，曝光包含本端适用的曝光基准。Mac/iOS/Windows 新增 Tool scope，Android 已有 Tool(Int) 继续复用且保留旧 tint alias 9。
- 外观移除遇到 active recipe 时，复用同一无损 detach/最终 Float 对等校验。技术方案4.2明确当前 master-recipe reset 也移除 film/look 与 recipe 身份、恢复 strength，并保留非外观有效值；不采纳“当前 recipe 必须保留其他外观身份”的无依据解释。无 recipe 时 Film 与 Strength 各自只改拥有字段，未选 recipe 的 recipe reset 是 NoChange。对移除 recipe 所需的显示值/模式转换列出实际变化项，blocked 显示六语解释，不直接渲染内部英文 reason 或 enum 名。
- HSL 菜单顺序：当前颜色（带色名）、全部 HSL、颜色组、全部调整；其他工具：当前工具、本组、全部调整。组/全部HSL/全部调整需确认；普通工具无变化禁用，recipe materialization 按真实转换决定确认。确认绑定 prepared snapshot，取消零提交，过期状态不覆盖新编辑。
- 几何/镜头当前工具 reset 只改当前 kind；group reset 同时修改同一 draft 中 geometry+lens，不写 committed。组切换、工具切换、收起/隐藏均复用既有草稿守卫及 save-first/retry。
- 全量 reset：先解决 active draft，再从新 committed prepare。原型 `app.js:1290-1342,1532-1542` 明确最终确认/取消后恢复原工具，并建立基于当前 committed 的新 unchanged draft；不得恢复已明确放弃的旧 draft。实现使用一个本端待办 reset intent，解决期间暂停自动重进草稿；如果 adapter 要等 exact/resize 收敛，绑定现有 ready 状态继续，不用任意 timer。确认全量之前取消保留已完成的 Apply/Discard。无变化全量零额外保存/预览。普通 reset 始终保留工具/channel。
- 面板边界只在用户展开/收起、窗口变化或桌面拖动时改变；移除按 tool/HSL/geometry/denoise 内容自动增高。组栏常驻、参数滚动、draft actions 固定可达。无照片隐藏调整区。
- 手机/窄窗/无障碍字号底部横滑；宽窗侧栏遵守 width>=600、width>height、非无障碍字号，并实际测量文字/触点是否可容纳六列，否则回退底部。iOS 44pt / Android 48dp 触点不能为320目标宽度缩小；不直接复制原型CSS常量。
- 保留 [处理版本契约](../../../lutools/docs/processing-version.md)：新照片默认版本2，缺字段的旧记录版本1；当前工具、整组、全部调整重置及草稿 Apply/Discard 都保留完整 processing identity。处理版本不作为第七组/第十八个工具，不参与调整标记；Mac/Windows 已有显式版本选择入口继续可达。版本变化须令旧 prepared candidate 失效。
- 除协调者持有的共享文案外，不改 Shared 代码、C ABI、算法、schema、copy/batch/undo、旧降噪或其它无关模块。新六语只增本批需要的来源/entries，保留 PR#74 已完成与 retained 决策，不做历史批量替换。

## Owner 与分支顺序

### 消费者前置：逐端工具与 scope 映射

以下为本批冻结的 current-tool 所有权表；它是本端适配说明，不是新的跨平台运行时 DTO。Mac 新增小型 `EditorAdjustmentTool`（下面17个逻辑工具）；iOS沿 `EditorToolSelection` 新增 `.tool(...)` scope；Windows沿已有 `EditorAdjustmentTool` 新增 `EditorResetKind.Tool` 与Tool字段；Android继续既有 `Tool(Int)`。所有组调用这些描述表，不能复用Mac旧八组或Windows旧中文组数组。

| 逻辑工具/组 | Mac现有路由 | iOS现有路由 | Android ID | Windows工具 | current-tool拥有字段/确认 |
| --- | --- | --- | --- | --- | --- |
| film / looks | dockCategory.film | .film | 0 | Film | 本端film/look选择；无recipe时仅清选择，保留strength和其他参数；若移除此look涉及active recipe，沿同一detach规则 |
| recipe / looks | dockCategory.masterRecipe | .recipe | 15 | MasterRecipe | 无active recipe为NoChange；有recipe复用4.2无损detach，清耦合身份并恢复strength；发生显示值/模式物化须确认 |
| strength / looks | .strength | .adjustment(.strength) | 1 | Strength | 仅strength/lutStrength/Values[Strength]回本端默认；不重放或移除recipe |
| exposure / light | .exposure | .adjustment(.exposure) | 2 | Exposure | 用户exposure及适用的exposureMode；raster沿已有sensor/none默认 |
| highlights / light | .highlights | .adjustment(.highlights) | 3 | Highlights | 仅highlights，沿本端默认/符号，不改转换公式 |
| shadows / light | .shadows | .adjustment(.shadows) | 4 | Shadows | 仅shadows |
| contrast / light | .contrast | .adjustment(.contrast) | 5 | Contrast | 仅contrast；保留本端0或1默认表达 |
| toneCurve / light | .toneCurve | .adjustment(.toneCurve) | 6 | ToneCurve | 仅现有legacy S曲线参数 |
| whiteBalance / color | .temperature（.tint alias） | .adjustment(.temperature)（.tint alias） | 8（9 alias） | WhiteBalance（Temperature/Tint旧参数入口alias） | WB模式+temperature+tint为同一工具，使用recipe-aware/as-shot默认；保留真实calibration metadata，不伪造6500/0 |
| saturation / color | .saturation | .adjustment(.saturation) | 7 | Saturation | 仅saturation |
| hsl / color | hslSelected | .adjustment(.hsl) | 14 | Hsl | 整体工具表示全部24值，若作为Tool scope则等价AllHSL且需确认；当前色域是独立HslChannel(index) scope，绝不能当普通Tool index |
| vignette / effects | .vignetteAmount | .adjustment(.vignette) | 12 | Vignette | amount/midpoint/roundness/feather/highlights完整5字段，不改变grain |
| grain / effects | .grainAmount | .adjustment(.grain) | 13 | Grain | amount/size/roughness完整3字段，不改变vignette |
| denoise / detail | .denoiseMode | .adjustment(.noiseReduction) | 11 | Denoise | Mac rawNoiseReduction+chromaNoiseReduction+waveletNoiseReduction；iOS noiseReduction+denoise+displayChromaDenoise；Android denoise+displayChromaDenoise；Windows Denoise+DisplayChromaDenoise；全部合法旧辅助字段随明确reset回默认，decoder/正常加载不迁移 |
| sharpening / detail | .sharpening | .adjustment(.sharpening) | 10 | Sharpening | 仅sharpening，不清denoise对象 |
| geometry / geometry | geometryDraftTab.geometry | .geometry | 17 | Geometry | 仅当前draft的完整geometry对象，保留lens；无对应active draft时Blocked |
| lens / geometry | geometryDraftTab.lens | .lens | 16 | Lens | 仅当前draft的完整lens对象，保留geometry；无对应active draft时Blocked |

组顺序和默认工具严格取上表：looks=[film,recipe,strength]→film；light=[exposure,highlights,shadows,contrast,toneCurve]→exposure；color=[whiteBalance,saturation,hsl]→whiteBalance；effects=[vignette,grain]→vignette；detail=[denoise,sharpening]→denoise；geometry=[geometry,lens]→geometry。WB alias永远不增加第18个可见工具。HSL channel为0...7、axis-major既有存储顺序不变，channel scope只重置该色域三轴。Group(geometry)与Tool(geometry/lens)必须分别测试：前者重置pair，后两者只重置匹配的当前kind。

来源已由协调者亲核：Mac `AdjustmentTypes.swift:218-228`/`Adjustments.swift:3-25,390-467`，iOS `EditorAdjustmentRules.swift:12-17,37-57,159-190`/`RawSettings.applyMasterRecipe`，Android `EditorAdjustmentRules.kt:45-55,112-154`，Windows `EditorAdjustmentRules.cs:3-34,110-148`/`Adjustments.cs:5`。精确行号随接线会移动，模型字段和既有converter才是代码事实来源。

1. 协调者：独占本批计划/总账、Shared/strings 来源与30个生成输出、必要CI selectors/policy与截图产物收集。拟基础分支 `feature/editing-workspace-groups-foundation`。资源先本地提交供消费者明确依赖；远端先合入基础PR。各UI分支从最新development创建，可显式merge同一基础提交作本地依赖，禁止复制生成文件形成分叉；前置合入后及时merge新target、只重验受影响增量。
2. Mac worker：`RawLabMac/Sources/Adjustments/AdjustmentTypes.swift`、`Adjustments.swift`；Editor Model Workflow/Geometry/必要state；EditorView/AdjustmentDock/AdjustmentPanelLayout；MacHSLMixer以及DenoiseControls/PhotoEffectsControls的既有高度/整工具reset回调。允许新增邻近的小型导航/重置UI文件。不碰shared资源、engine/core/CI。分支拟 `feature/editing-mac-workspace-groups`。
3. iOS worker：Core/Models/EditorAdjustmentRules、Core/ViewModel/EditorResetTransaction；ContentView/Helpers/Panels、EditorDrafts/EditorLayout、AdjustmentPanels/PhotoEffectPanels；必要project source注册。不重做AdjustmentControl/Ruler或processor。分支拟 `feature/editing-ios-workspace-groups`。
4. Android worker：editor rules/state/VM 的窄UI查询适配、EditorScreen/EditorTools/AdjustmentDock、HslControls channel binding、MainActivity回调、AdjustmentInteraction布局policy；必要既有工具整对象reset回调。不改JNI/codec/renderer/Shared。分支拟 `feature/editing-android-workspace-groups`。
5. Windows worker：EditorAdjustmentRules/EditorResetTransaction/EditWorkflow；MainWindow.xaml/.xaml.cs、Tools/Commands/Rendering/Transform必要接线；HslPanel channel seam。保留同dialog save-first，不改Library批量路径。分支拟 `feature/editing-windows-workspace-groups`。

共享源文件只有一个 owner；平台 worker 不改 Shared 或生成资源。测试按各端既有tests目录归平台owner。所有任务先行为RED，再最小实现；独立默认代理复评和主线程关键路径复核，不依赖实现者自报。

## 必须验证的行为

- 六组顺序/default tool/重复点击收起/跨组一次切换/无照片隐藏；稳定工具ID与六语标题/无障碍状态，导航不落盘。
- HSL channel 跨组/工具保留；打开/取消 reset不改变channel或输入精度。HSL范围、其他组/工具字段保持；current tool与group不能混用。
- 普通/geometry/lens/recipe-active当前工具 reset，关闭辅助字段、合法旧值、缺WB/不可表示blocked；current recipe不能绕过detach/确认。普通reset一次编辑/预览，NoChange/stale/cancel零效果。
- dirty draft切组/收起/隐藏、保存失败留在原处、retry成功只执行目标一次；全量reset的Apply/Discard/Stay→独立确认/取消→恢复原工具及fresh unchanged draft；后一步取消不撤销前一步。
- 固定panel边界：切所有tool、保存错误/busy、draft action显隐外框不动；只内部滚动。代表窄窗/宽窗、长语言、大字号且最后控制可达；原生截图视觉检查，浏览器原型不是原生证据。

## 既有验证入口

- 资源：`python3 scripts/localization/generate.py --check`、现有GeneratorFormatTests/GeneratorSourceTests及平台本地化静态检查；每个新增source恰好六语、placeholder与entries匹配，不手改生成输出。
- Mac：build.sh；control-groups/edit-model/presentation；真实EditorView的compact-controls-presentation六语950x620/1440x900与geometry draft原生交互。需补能够实际点击组与reset确认的窄harness，不能只截图或只测纯model。禁止用CUA在隔离App退出后重新查询以免脱离隔离启动。
- iOS：edit-memory/presentation+必要布局policy；专属iPhone/iPad simulator app/test build及真实group/reset UI和原有draft回归。相同source/architecture/config framework才可复用；记录source与截图/运行证据，真机另列缺口。
- Android：完整JVM、lint、app/androidTest；任务私有ADB/AVD显式serial，真实Compose group/reset/pending flow与原9项回归。先迁移实际依赖flat strip的测试helper，保留工具AX ID并加group ID，不放宽断言。标准RAW为既有DSC00316.ARW；保留早期NEF状态差异历史。
- Windows：managed+WPF crosscompile；真实Windows CI选tool-groups/ui-details/editor-shell/editor-review/localization-ui，保留第三批transform-ui。1024x720/宽窗真实layout/screenshot。CI配置由协调者接，不把crosscompile当runtime。
- 重型native构建与专属设备执行由协调者错峰；共享下载缓存只读复用，不跨source/platform/architecture/config混用编译输出。每端完成后清理自己的资源，保留日志/截图/JSON/manifest。

## 执行与验收状态

- resource owner 已汇总 26 个新增共享来源、4 个复用来源，完整六语、原生 keys/formats/types 的生成预检通过；30 个输出均无既有译文删除或改写。基础分支正式落地及验证后再发固定提交给四端消费。
- CI基线：#115–#118 联合 CI 全部通过。随后合入 #106 的 `0fd52624` 由 [39629200983](https://github.com/dancancer/RawLab/actions/runs/39629200983) 验证；各实现 PR 仍须最新源提交的独立评审和 CI。
- `impeccable context` 已在协调树执行一次，主线程已读PRODUCT/DESIGN和Mac/iOS surface briefs；`.impeccable/design.json` 被报告为旧sidecar，仅记录，不在本批顺手刷新。旧DESIGN/brief记录现有单行工具栏，新增六组采用本次需求/技术方案的明确变更，不从旧sidecar推导规则。UI编辑前各owner读craft-floor；现有需求已明确，无需重复设计访谈或另造visual world。

## 本批完成门槛

- [x] Task 0：共享六语生成、CI运行入口、计划与集成总账完成本地验证和独立复核；hosted CI 随基础 PR 验证。
- [ ] Task 1：Mac原生六组/current-tool/reset/固定面板及实际交互、六语截图通过。
- [ ] Task 2：iOS原生接线、iPhone/iPad实际界面及草稿回归通过。
- [ ] Task 3：Android原生接线、JVM/lint及实际Compose/VM/草稿回归通过。
- [ ] Task 4：Windows原生接线、managed/crossbuild及CI实际WPF回归通过。
- [ ] 四端独立复核、协调者关键调用链核验；获得远端操作授权后集成并核实联合CI。

纯模型、编译、模拟器、真实硬件分别登记；本批完成也不代表整个S2或ITER-02验收通过。
