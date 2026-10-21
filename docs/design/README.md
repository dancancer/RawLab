# RawLab 设计资产

这里维护可继续编辑的设计源文件、跨平台交互规则和设计决策。产品范围以 [PRODUCT.md](../../PRODUCT.md) 为准，已确认的视觉与交互基线以 [DESIGN.md](../../DESIGN.md) 为准，交付顺序见 [roadmap](../architecture/roadmap.md)。设计通过评审不等于功能已经实现。

| 资产 | 用途 | 状态来源 |
| --- | --- | --- |
| [本次迭代总需求](editing-iteration/requirements.md) · [总技术方案](editing-iteration/technical-design.md) | 第一阶段未完成项＋第二阶段全量＋桌面更新；新增功能、依赖和 IT 验收总表 | 两份文档的状态与基线；工作区是其中 ITER-02 子项 |
| [四端应用设计资产](editor-workspace/README.md) · [设计板](editor-workspace/index.html) · [覆盖表](editor-workspace/coverage.html) | 四端现有完整功能界面；本轮分组、HSL、前后对比与桌面更新；共用图标、状态和检查工具 | [manifest.js](editor-workspace/manifest.js) |
| [调整记忆与批量导出](2026-10-09-edit-memory-batch-export/README.md) | 既有已确认方案与静态参考图 | 该目录 README；保留历史来源，不把图片当运行证据 |

ITER-02 工作区子项：[详细需求](editor-workspace/requirements.md) · [技术方案](editor-workspace/technical-design.md)。文档沿用四端 r4 设计基线，不代替整轮迭代的总范围。

## 后续如何维护

- 修改现有界面时先打开对应资产，沿用其共用模型、语义颜色和平台入口；同一界面的后续改版在原目录继续修改，通过 Git 查看历史，不为每次评审复制一个新目录。
- 新增独立工作流时才增加资产目录，并在本表登记。每项资产必须包含目标、范围、入口、来源、评审状态、版本和维护说明，避免只留下无法继续编辑的截图。
- 原型源文件是可审阅的设计表达。原生界面的参数和运行行为仍以对应代码、共享契约和验证结果为准；发现差异时记录决策，不悄悄把设计稿改成与实现相同。
- 设计变更先进入待评审状态；用户确认后记录确认依据，再更新对应的 `DESIGN.md` 规则及受影响的 surface brief。实现完成另按实际平台证据登记，不用设计截图证明功能已交付。
- 本地浏览器截图和临时导出不作为第二套设计源文件；需要保留的长期参考素材必须说明来源和用途。不要把 RAW 样片、个人路径或应用数据放进设计包。
