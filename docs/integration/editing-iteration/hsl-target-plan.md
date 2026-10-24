# ITER-07 HSL 图片取色与目标调整接入计划

> **For agentic workers:** 使用 `superpowers:executing-plans`，由协调者实现；独立代理只读复核。

**Goal:** 四端从真实照片选取一个或相邻色域，在指定 H/S/L 轴拖动或按键调整，一次输入形成一个可撤销事务。

**Architecture:** additive C ABI 创建带 source/request revision 的不可变 pre-HSL CPU 图像快照。
它复用现有 tone/vibrance 与几何链，采样共享 HSL 的 hue/weights；客户端只负责结果图坐标、当前帧校验和输入事务。

**Tech Stack:** C++17、Swift/UIKit/AppKit、Kotlin/Compose、C#/WPF；保留既有八色域算法、24 个持久化值和历史入口。

**Spec:** [总需求 §9](../../design/editing-iteration/requirements.md#9-hsl-取色与目标调整iter-07)、
[技术方案 §9](../../design/editing-iteration/technical-design.md#9-iter-07hsl-取色与目标调整)。
用户已批准本轮实现并要求继续后续迭代，实际界面待解锁后统一验证。

## 共同约束

- 本地 `feature/editing-hsl-target` 依赖 ITER-06 检查点 `f7220f1`；远端基线已刷新为 `751f21c5`，本批无 push/PR/合入授权。
- request v2、HSL 配置和持久化结构不改；取色位置、权重、轴和快照只属会话。
- 快照截止于 tone/vibrance 之后、HSL 之前，再使用相同 crop/rotate/perspective/resize；RAW 已包含 lens/orientation，不重复变换。
- 快照明确为 CPU reference，PREVIEW 继承请求的代理质量，不承诺与全分辨率或 GPU 纹理逐像素相同。
- revision 由客户端给定并冻结；核心检查 query 与快照一致，客户端另外检查当前照片/已接受帧/编辑状态，过期结果不得应用。
- 归一化位置范围 `[0,1]`，端点对应第一/最后像素中心；参考图、标签、遮罩、留白在画布层拒绝。
- 非有限像素或 RGB spread 小于 `1/255` 不选择色域；权重由既有 smoothstep 产生。
- 手势冻结逻辑 HSL（不含 recipe strength）、轴和权重；所有增量从 before 计算并限幅 `[-100,100]`，结束一次提交、取消回滚。

## 复核重点

- HSL/分级/颗粒改变后不能反过来改变下一次取色依据：T1。
- 透视、转向、裁剪、缩放及并排/分割参考的坐标和遮挡：T1/T3。
- 异步取色返回时已切源、渲染更新或输入已取消：T2/T3。
- 连续 move、端点限幅、三轴、相邻两域及 recipe strength 为零：T2。
- 多指、失焦、后台、Escape、切工具/轴/色域及几何草稿必须回滚且不产生历史：T3。

## T1：核心不可变取色快照

**Files:** `lutools/src/core/photo_color.{h,cpp}`、`src/ffi/sony2fuji_c.cpp`、
`include/sony2fuji/ffi/sony2fuji_c.h`、`tests/hsl_probe_tests.cpp`、CMake 与颜色合同。

**Interfaces:** `HslColor`/`analyzeHslColor(RGB)` 复用原 hue、HSL 和邻域权重；
`sony2fuji_session_create_hsl_probe(session,request,source_revision,request_revision,out_probe)`；
`sony2fuji_hsl_probe_sample(probe,query,result)`；`sony2fuji_hsl_probe_destroy(probe)`。
快照拥有几何后的 float RGB，query v1 包含元信息、两个 revision 和归一化 x/y；
result 返回 availability、CPU 质量标识、尺寸、revision、RGB、H/S/L 和八权重。

- [x] 先补失败回归：红/橙中点、红色环回、灰/非有限/越界/revision 拒绝、三个轴共享原权重；原 HSL 图像不变。
- [x] 提取共享分析，接同一个渲染前缀；快照独立于后续 session 修改，明确释放，所有失败清空输出。
- [x] 验证 tone/vibrance 生效且 HSL/grading/detail/effects 不反馈、所有几何组合、RAW/raster 与代理尺寸；采样不改 session GPU 模式和已报告尺寸/backend。
- [x] 运行受影响 CPU/Metal/RAW 回归；文档写明质量与 revision 的两层责任。

## T2：四端取色模型与冻结事务

**Files:** `Shared/HSLTargetAdjustment.swift` 与现有 Apple HSL/native wrapper；
Android/Windows 同职责 target model、native wrapper/JNI 和模型测试。

**Interfaces:** 统一轴枚举；样本包含八权重及 revision，冻结 before 后 `values(delta)` 按轴从起点计算；
客户端通过既有串行渲染队列创建/采样/释放快照。无新保存字段，无第二套历史栈。

- [x] 先补失败回归：两色域独立加权、三轴、重复 delta 不累加、反向/端点、未选字段保持、取消与过期结果拒绝。
- [x] 接 native sample 和 UI 会话状态；异步返回需仍匹配启动照片、帧及编辑版本。
- [x] 跑四端模型与桥接编译；失败状态可区分近灰、图外、过期与处理失败。

## T3：四端真实画布与混色器入口

**Files:** 四端 HSL panel、photo canvas、editor/view model 的输入与生命周期入口；六语源和生成资源；对应 UI 测试。

**Interfaces:** HSL 面板切换目标模式与轴；画布将点转入实际结果 image bounds，排除标签/对比参考；
开始、变化、完成、取消复用既有 adjustment interaction。移动端显示放大取样提示，桌面支持方向键及 Escape。

- [x] 接入口、三轴选择、色域/失败提示及取样标记，保留普通 HSL 滑杆。
- [x] 接 zoom/pan/crop/留白/对比坐标与移动放大提示；冻结样本后拖动方向固定，不能重新取样反馈。
- [x] 接生命周期取消与一次历史提交；补充纯模型、原生 EditorModel、JNI 和真实画布回归。
- [ ] 解锁后执行四端三轴、相邻色域、移动放大提示及取消的实际 UI 回归，覆盖六语/大字。
- [x] 运行可执行的模型、native 与构建检查，独立只读复核并修复；实际 UI 留待解锁，不把编译称执行。

## T4：本地检查点

- [x] 记录源码与产物绑定、实际检查和待验项；清理不再需要的本次中间文件。
- [x] 保存本地依赖检查点，继续后续迭代；IT-08/15 待实际界面联合验收，不能提前关闭。

## 当前验证边界

核心、共享模型和四端桥接使用同一 pre-HSL 合同。Mac 原生 EditorModel 已执行 pending release、一次保存、取消、undo/redo、切源迟到结果回归；Android 已增加对应 ViewModel/JNI/Compose 检查，Windows 已增加 native sample 与 MainWindow 检查，iOS 已增加 processor 和真实编辑器检查。设备和窗口交互仍须解锁后执行，三轴、相邻色域、放大提示、六语/大字以及多指/失焦不能仅凭编译验收。
