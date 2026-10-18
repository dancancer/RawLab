# 共享文案来源

四端六语的 `Localizable.strings`、Windows 本地化 JSON、Android 的
`strings.xml` 和 `editor_strings.xml` 都是生成文件，禁止手改。
客户端继续读取原生资源，不改构建系统或运行时代码。
iOS 的 `InfoPlist.strings` 不属于此次迁移范围。

## 来源结构

- `common/catalog.json`：至少两个平台使用的中性中文原文，映射到六语译文。
- `platforms/{macos,ios,windows,android}.json`：四个平台清单，每个文件含三个字段。
- `entries`：保留该平台原来的键，指向 `source`；`formats` 按零起点参数顺序记录原生格式。
- `unique`：只有该平台使用的原文及六语译文，不与共享来源重复。
- `overrides`：共享原文在该平台必须不同的六语原值，以及明确的 `reason`。

Android 的 `entries` 以资源名为键，另外记录 `file`（`strings.xml` 或
`editor_strings.xml`）和按参数顺序排列的 `types`（`d`、`s`、`f`）。
同一中文原文可以被多个资源名引用；不按资源名猜测含义。
新目录每层至多四个文件。

## 生成与检查

在仓库根目录执行，Python 3 标准库即可，不需要 `plutil`、第三方包或网络：

```bash
python3 scripts/localization/generate.py
python3 scripts/localization/generate.py --check
```

`--check` 不写文件，逐字节检查全部 30 个输出，并拒绝额外的 Apple
`Localizable.strings`、Windows JSON、Android 字符串/复数/数组资源文件。
添加原生文件中的手写词条、丢失文件或仅改变空白都会失败。
来源还会检查六语完整性、唯一/共享归属、孤立来源、覆盖理由和参数类型。
Linux CI 同时运行无需 Apple 工具的 `GeneratorFormatTests` 和 `GeneratorSourceTests`。
测试临时目录遵循 Python 的 `TMPDIR`，可在本地设为任务专用目录。

修改文案只改来源，再运行生成与检查。新增条目时，同时维护实际使用平台的
`entries`；变为多端使用时，将 `unique` 中的译文移至 `common`。
翻译优先级固定为 Mac、iOS、Windows、Android，不能以其他平台的措辞反写 Mac。
仅在确有平台差异时使用覆盖项，不能用覆盖绕过普通译法或大小写统一。

## 占位符与转义

来源内只使用 `{0}`、`{1}` 等中性参数，字面花括号写成 `{{`、`}}`。
原生类型、符号和精度放在 `formats`，不混入译文：

- Apple：`%@` 等保持原类型；译文调序时使用 `%2$@` 等位置参数。格式化字符串的
  字面百分号恢复成 `%%`；普通非格式化文本保留 `%`。
- Windows：保留 `{0}`、`{1:0.#}` 等完整原生格式；JSON 采用四空格缩进且不写注释，
  因为现有 `System.Text.Json` 读取器不接受注释。
- Android：始终生成位置参数，保留 `%1$d`、`%1$s`、`%1$+.1f` 的类型和精度；
  有参数时字面百分号为 `%%`。无参数时保留普通 `%`。
- Apple 使用 UTF-8 和引号、反斜杠、换行转义；Android 同时进行 XML 与 Android
  字符串转义，包括引号、单引号、反斜杠、换行、`&`、`<` 和开头的 `@`、`?`。
  Android 外层引号用于保留连续空格和首尾空白，不属于最终显示文字。

Apple 与 Android 文件带生成器提示。键按 Unicode 码点排序，文件统一 UTF-8/LF。

## 迁移审计

迁移基线为 `c74e3ea`，所有翻译机械取自原目录，没有新写译文。
数量、平台覆盖依据、检查结果及待协调冲突见 [迁移记录](migration.md)。
基线提交在本地可用时，可重新生成完整审计文件：

```bash
python3 scripts/localization/audit.py --base c74e3ea --output <报告目录>
```

该命令核对每个文件的键集合、每个参数的原生类型/精度、Android 中文反查，
以及共享译文优先级、特有译文和覆盖项是否原样保留；任一违反都会失败。
输出 `value-changes.tsv`、`key-sets.tsv`、`android-reverse-lookup.tsv` 和
`migration-summary.json`。TSV 的文本字段用 JSON 字面量表示，换行不会拆行。
