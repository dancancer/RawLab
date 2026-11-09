# 相机传图设计

- [Sony UI 与交互逻辑](ui-interaction.md)：首版 Mac 相机导入窗口、连接、挑选、传输、恢复及编辑交接。
- [可点击交互原型](prototype/index.html)：默认进入选片，可用顶部场景菜单查看首次连接、断线、部分失败、空间不足和草稿门禁。
- [移动端 UI 与交互](mobile-ui-interaction.md)：iOS、Android、前台传输与恢复、平板和大字适配。
- [Android 系统媒体库](android-media-library.md)：原件保存位置、拍摄日期分目录、恢复及相册编辑身份。
- [移动端交互原型](prototype/mobile.html)：iPhone / Android 对照、单端和平板视图；可操作选片、筛选、预览、导入与编辑交接。
- [Sony 协议与架构设计](sony-wifi-design.md)：协议分代、持久原件与跨平台边界。
- [跨品牌 SDK 调研](vendor-sdk-survey.md)：其他品牌仅调研。
- [已实现的桌面协议工具](../../../tools/camera-transfer/README.md)：当前实现边界与用法。

静态原型设计版本为 r1；Mac 与 iOS 保留设计提案，Android 正式入口已实现，当前边界以移动端 UI 和系统媒体库文档为准。
主流程采用用户确认的「挑选几张，再导入编辑」。
原型是静态 HTML/CSS/JavaScript 设计资产，可直接打开 `prototype/index.html`，无需安装依赖或构建。
它不访问相机、不保存凭据、不处理或写入真实照片；缩略图和拍摄元数据均是设计示例。
Mac 原型的浏览器窄窗口只用于保持该原型可读；独立移动端原型表达 iOS/Android 的设计提案，
两者都不代表原生实现或设备验收。

原型沿用当前 [DESIGN.md](../../../DESIGN.md) 的 Mac 界面语法，未替换全局设计系统。
实际原生编辑器仍以各平台客户端代码为准；原型里的编辑器和选片集合只展示导入后的交接位置。
移动端继承现有 iOS 系统控件与 Android Material 3 主题，在导航、筛选、触点和生命周期上分别适配。

## 素材

`prototype/assets/` 中的六张照片为 Unsplash 摄影示例，各自来源记录在
[sources.json](prototype/assets/sources.json)。不是用户相机上的照片，也不是 Sony 协议实测结果。
示例文件名、拍摄时间、大小、相机地址和指纹均为原型数据。
