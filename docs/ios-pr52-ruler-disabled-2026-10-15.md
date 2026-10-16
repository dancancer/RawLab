# PR #52：刻度禁用候选的动态核验

结论：候选 2 **未证实为用户可达缺陷**。真实 SwiftUI hosting 环境会在父视图禁用后撤销刻度的 first responder，并把实际 AX 节点导出为 Disabled。系统方向键、真实触摸以及跨越禁用切换的进行中拖动均未继续回写。本项没有修改 `AdjustmentRuler.swift` 或增加产品 guard。

## 源码与环境

- 审查基线：`683ee98c92d323d6c38f0f09f402357f4649d4e6`，工作树 `ios-editor-v4`。本项使用生产 `AdjustmentRuler`、`AdjustmentScale`、`AdjustmentControl` 与 `NativeValueWheel`，通过 `swiftc` 编译成独立 UIKit + SwiftUI hosting app；不复制刻度实现。刻度产品源码相对基线零 diff。
- 专用设备：`RawLab PR52 Ruler Busy`，UDID `945EADF7-3A48-4AB0-B9B4-1490DFFC86DC`，iPhone 16 Pro / iOS 27.0。只创建、启动和使用此设备，没有操作其他设备或真实桌面。
- XCTest runner 从已有 build-for-testing 产物复制到本项 `/tmp`，只替换复制品的测试 bundle；没有修改项目文件或原 runner，也没有运行无关测试。

## 最终通过结果

**1 / 1 XCTest 通过，0 失败、0 跳过，16.722 秒。** 最终源码对应的结果为：

- `/tmp/rawlab-pr52-ruler-system-final-2/ruler-enabled-ui.xcresult`
- `/tmp/rawlab-pr52-ruler-system-final-2-driver.log`

测试先用实际拖动让刻度取得键盘焦点，再通过 XCTest 的系统右方向键确认数值增加一步。测试安排一秒后禁用父视图，使用每秒 40pt 的真实慢拖动跨过禁用时刻。`editingAtLock=true` 确认禁用发生于进行中的实际 pan；之后 `editing=false`，余下拖动停止回写。

禁用生效 80ms 后的快照为 writes=5、value=13，拖动结束仍为 5 / 13。该延时用于让 SwiftUI 完成环境传播，不作为性能测量。此后实际系统左右方向键和新的触摸拖动仍保持相同 writes/value。解锁后重新拖动可以写入。

真实 XCUI AX 树的同一节点从 `enabled=true` 变为 `enabled=false`，快照明确包含 `Disabled`；`isHittable` 仍为 true。后者表示可命中的几何位置，不能等同于控件启用。

## 方法级观测与边界

另对最终同一已编译 app 执行观测，进程退出 0，输出 16 个字段：

- `/tmp/rawlab-pr52-ruler-system-final-2/method-observations.json`
- `/tmp/rawlab-pr52-ruler-system-final-2/method-probe.log`

启用时 `becomeFirstResponder` 成功，`UIApplication.sendAction` 右方向键返回 true，value=11。父视图禁用后仍是同一个 UIKit 刻度，`isFirstResponder=false`、`isUserInteractionEnabled=true`；使用禁用前保存的左右 key command 经真实 responder chain 派发均返回 false，binding writes 增量为 0。

直接调用 UIKit `accessibilityIncrement()` / `accessibilityDecrement()` 方法确实仍各回写一次，value 为 11 / 10；`canBecomeFirstResponder` 也仍返回 true。这些是绕过系统 AX 派发的方法级观测。实际导出的 AX 节点已禁用，不能把方法直调写入计作 VoiceOver 用户可以绕过禁用，更不能据此新增产品 guard。

真实硬件 VoiceOver 增减、物理键盘、iPad、其他系统版本及导入/保存/降噪各自完整业务链没有在本项运行；本项覆盖生产 representable 的父级 `.disabled` 边界。没有声称实际 VoiceOver action 已派发或硬件辅助功能已验收。

早期探索探针曾把 UIKit 自身 trait / recognizer 必须同步禁用等强预设写成断言，得到 17/25、8 个失败；随后真实 AX 树与系统输入证明不能把这些预设当作产品缺陷。该探索结果不计入最终通过数。辅助源码编译问题已在测试代码中修正，最终新源码重新编译并运行上述 16.722 秒测试；此前 13.534 秒的初步 UI 结果不冒充最终结果。

## 精确复现命令

最终 UI 回归（脚本已包括 harness 编译安装、复制并编译 runner、仅运行一个 XCTest）：

```sh
bash RawLab/tests/adjustment-ruler-enabled-ui.sh \
  945EADF7-3A48-4AB0-B9B4-1490DFFC86DC \
  /tmp/rawlab-pr52-review-derived/Build/Products/RawLab_iphonesimulator27.0-arm64.xctestrun \
  /tmp/rawlab-pr52-ruler-system-final-2 \
  > /tmp/rawlab-pr52-ruler-system-final-2-driver.log 2>&1
```

最终同一 app 的方法级观测：

```sh
SIMCTL_CHILD_RAWLAB_RULER_RESULT=/tmp/rawlab-pr52-ruler-system-final-2/method-observations.json \
  xcrun simctl launch --console --terminate-running-process \
  945EADF7-3A48-4AB0-B9B4-1490DFFC86DC com.rawlab.tests.ruler-enabled \
  > /tmp/rawlab-pr52-ruler-system-final-2/method-probe.log 2>&1
```

`bash -n RawLab/tests/adjustment-ruler-enabled.sh RawLab/tests/adjustment-ruler-enabled-ui.sh` 两个脚本语法检查通过，`git diff --check` 通过。若重跑，选择新的输出目录以保留原测试记录。
