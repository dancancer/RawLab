# 相机品牌无线传图 SDK 与协议调研

调研日期：2026-11-08。版本：1。状态：公开资料调研，未做 SDK 集成、授权申请或相机实测。
本轮只为 [Sony 设计](sony-wifi-design.md) 提供后续扩展依据；用户已明确其他品牌暂不实施。

## 1. 结论与术语

**不存在已经核实、能让四端一次覆盖所有相机的统一官方 SDK。** 多品牌接入需要统一业务合同与按品牌、
型号、固件划分的适配器；部分设备只能经官方 App 中转或使用其他连接方式。
对 RawLab 有价值的是“卡中已经存在的照片能否按原始字节传入”，不能仅验证遥控拍摄或实时取景。

“有开放 SDK”在本文拆成三种情况：

- **可公开获取的协议/源码**：第三方可阅读，但仍需看协议、示例和二进制各自许可。
- **可申请的厂商开发包**：需要账号、企业申请、相机序列号或许可协议，免费不代表开源或自由分发。
- **只有官方 App/合作接入的证据**：不能当成可供 RawLab 使用的公共接口。

本次覆盖主流可换镜头/便携相机品牌，并附运动、全景和手持设备。不是全球所有品牌型号的完整清单；
未查到公开接口只表示本次证据不足，不断言不存在合作或非公开 SDK。

## 2. 品牌比较

| 品牌 / 接口 | 第三方入口与开放程度 | 无线 / 平台 | 卡内已有照片与原图证据 | 后续判断 |
| --- | --- | --- | --- | --- |
| Sony Camera Remote Command / SDK | 企业可申请 Command；SDK 为专有开发包，旧 Camera Remote API 已停止支持 | Command 有 PTP-IP，逐机型确认；SDK 为 Windows/macOS/Linux，未列 iOS/Android | 公开总页不足以给出逐机型 ARW 枚举/下载结论；手机模式、PC 模式、FTP 分开 | **本期重点**，详见主设计 |
| Canon CCAPI | 官方 HTTP API，需按地区申请并按机型激活；不是开源 SDK | Wi-Fi，部分机型 LAN；HTTP 路线不依赖特定客户端语言 | 官方功能表明确含存储、DCIM、内容列表和 original/thumbnail/embedded；完整 CR2/CR3 仍按机型确认 | **Sony 后优先核实的传统相机路线** |
| Canon EDSDK | 官方专有、可申请开发包 | Windows/macOS/Linux；官方资料列 USB/PTP | 支持图像传输；不把 USB 能力记作 Wi-Fi 能力 | 适合作为未来有线补充，非本次无线基础 |
| Nikon Remote SDK / MAID / MTP | 免费申请，库与规格受许可约束；Image SDK 是另一种本地 RAW 解码库 | 桌面远程控制，当前包的平台版本按更新说明；公开页未充分确认 Wi-Fi 链路 | 未核实当前 Remote SDK 的无线卡内既有 NEF/NRW 枚举与原文件下载合同 | 有开发入口，先取规格再决定；SnapBridge 不是 SDK |
| FUJIFILM Camera Control SDK | 有面向个人/企业的专有开发包 | Windows/macOS/Linux；USB 或经 AP 的 TCP/IP；Android 页面明确仅 USB，未列 iOS | 官方确认自动图像传输，但卡内旧照片枚举、原始 RAF 下载与新拍传输的区别待查 | 桌面候选；不能承诺四端无线 |
| Panasonic LUMIX SDK | 公开介绍、接受许可并输入相机序列号下载，标为 Beta | 页面列 Windows 10 64 位、USB；BGH1/BS1H 另有 Ethernet，未确认 Wi-Fi SDK | 有图像副本获取、保存到 SD/PC；是否任意旧照片与 RAW 未核实 | 有 SDK，但当前证据不满足无线直连方案 |
| OM SYSTEM / Olympus | 本次未查到通用公开相机 SDK；有 OM Capture / OI.Share | 官方软件有 USB 和部分机型 Wi-Fi 工作流 | OI.Share 可选相机已有照片，RAW 支持按机型；官方 App 能力不能等同第三方接口 | 暂列协议/合作资料待核实 |
| RICOH / PENTAX | 官方历史 Camera USB/Wireless SDK，当前分发与维护状态需复核 | 历史体系含桌面 USB 和移动无线；不能外推 GR 全系列 | 图像处理文档仍有历史索引，但当前正文链接失效；既有 RAW 下载待重新取得资料确认 | 有相关历史接口，需确认现在是否可用 |
| Leica | 未查到通用公开相机 SDK；FOTOS 和合作软件集成有官方证据 | FOTOS 无线；USB PTP 为另一条路线 | FOTOS 可传 DNG；不证明第三方能访问 FOTOS 协议 | 协议/合作路线待核实 |
| Hasselblad | A6D 有按申请提供的 Windows Phocus SDK；不能扩大为 X/V 系列开放 SDK | A6D SDK 主要为 USB tether；Phocus Mobile 有 Wi-Fi/USB-C | Mobile 可导入 RAW；A6D SDK 旧卡内容语义未确认 | 普通 X/V 无线 SDK 未查实 |
| SIGMA | 有 Camera Control SDK，官方资源页提供 Windows/Mac 包 | 已确认 fp 官方 SDK 路线为 USB；未核实无线开发接口 | 官方介绍聚焦 tether 和控制，既有卡内文件需查规格 | 不能因 RawLab 能解码 X3F/DNG 就声称无线接入 |
| Phase One | 有 CameraSDK 与独立 ImageSDK，公开文档、受许可开发包 | 当前文档列 Windows/Linux；传输文档提到 Wi-Fi，但需逐机型确认链路 | Image Browsing 明确可列相机存储并下载整个 IIQ | 有直接文件能力证据；移动端与机型无线覆盖待核实 |
| GoPro Open GoPro | 公开 API、文档与示例许可清晰；另有需申请的移动控制 SDK | BLE/Wi-Fi/USB，HTTP 媒体下载 | 明确提供 SD 卡媒体列表和文件传输；RAW 类型、具体型号仍需确认 | 接口开放度较高，但与 RawLab 的静态 RAW 使用场景分别评估 |
| DJI Mobile SDK | 开发者平台和媒体 API，需 App Key，受产品支持矩阵约束 | Android/iOS；取决于产品的 Wi-Fi/USB/遥控器链路 | MediaManager 可列卡内媒体并下载原文件；旧 Osmo 文档不能推导现售 Action/Pocket 兼容 | 按目标型号核实，不能写“所有 DJI 相机” |
| Insta360 SDK / OSC | SDK 需申请审批；另有 OSC 接口 | SDK 桌面仅 USB；Android USB/Wi-Fi/BLE，iOS Wi-Fi/BLE；OSC 可 Wi-Fi | 官方 SDK 明确有文件列表/下载；特殊格式、原始照片与拼接输出分别确认 | 移动端候选；桌面无线需另验 OSC |

## 3. 主要依据与剩余问题

### Canon

官方 [日本 API Package](https://personal.canon.jp/product/camera/software/api-package) 与
[澳大利亚开发页](https://www.canon.com.au/apps/eos-digital-software-development-kit) 区分 USB EDSDK 和无线 CCAPI。
[中国开发页](https://www.canon.com.cn/supports/sdk/icp/) 列出 CCAPI 的 UPnP/HTTP、Wi-Fi/LAN，以及申请、沟通、签约、下载流程。
[CCAPI 功能表](https://www.canon.com.cn/supports/sdk/icp/template/CCAPIdetail.pdf) 给出存储目录和原始内容访问，
因此它比“仅支持 remote shooting”的证据更贴近 RawLab 的需求。

后续核对相机是否需要 CCAPI 激活、固件、认证、CR2/CR3 表示、分页和大文件；不能把需 USB 激活的步骤隐藏成全程无线。
地区申请资格和应用分发条件必须按实际申请主体确认，不能跨地区直接套用。
[官方操作指南](https://downloads.canon.com/sdk/CameraControlAPI_OperationGuide_EN.pdf) 提供激活与 Wi-Fi 连接说明。

尤其是 [Canon 中国申请页](https://www.canon.com.cn/supports/sdk/icp/) 的“软件开发包申请说明”
包含个人/企业内部使用、限中国大陆使用和不得直接或间接出口许可软件的条款，并注明以正式软件许可协议为准。
这不是全球 Canon 条款的统一结论，但对 RawLab 面向多地区公开分发构成必须提前确认的实际条件。

### Nikon

[SDK 申请页](https://sdk.nikonimaging.com/apply/) 和 [FAQ/更新记录](https://sdk.nikonimaging.com/information/en/)
确认 Remote SDK、MAID/MTP 文档以及独立的 NEF/NRW Image SDK。更新记录显示型号、固件和操作系统支持会变化，
例如新的统一 Z 系列包与旧分机型包不能混为同一支持范围。FAQ 表明免费并需同意许可，不提供技术支持。

本次未取得受许可的具体归档，不能确认当前 Remote SDK 的 Wi-Fi 既有文件下载能力。
[SnapBridge](https://imaging.nikon.com/imaging/lineup/software/snapbridge/) 的自动缩图与手动原尺寸下载、
[NX Field](https://imaging.nikon.com/imaging/lineup/software/nx_field/) 的 LAN/FTP 多机工作流均是官方产品证据，
不能据此声称存在相应公共手机 API。Image SDK 能打开 NEF 也不能证明相机可无线发送 NEF。

### FUJIFILM

[Camera Control SDK](https://www.fujifilm-x.com/global/camera-control-sdk/) 明确 USB 与经无线接入点的 TCP/IP，
支持桌面系统，Android 只列 USB；能够自动传输图像，不提供 RAF 转换信息。
后者不妨碍 RawLab 使用自己的解码器，但“能传图”仍需核对是否能选取原先在卡中的 RAF。

官网与 [许可页](https://www.fujifilm-x.com/global/camera-control-sdk/agreement/) 有个人/企业使用和保修相关条款。
SDK 使用、再分发、源码组合、目标客户告知应单独确认；不能因为有公开下载入口就当作开源依赖。

### Panasonic

[LUMIX SDK 官方页](https://av.jpn.support.panasonic.com/support/global/cs/soft/tool/sdk.html)
明确为 Beta，列 Windows 10、USB 和仅 BGH1/BS1H 的 Ethernet；提供 DLL/header/API 文档/示例。
图像副本获取不自动证明任意旧照片目录读取，更不等于 Wi-Fi。
目前可据此确认“有 SDK”，但不能推荐它直接承担 RawLab 四端无线传输。

### OM SYSTEM / Olympus

[OM Capture](https://software.omsystem.com/omcapture/en/features.html) 描述拍摄后自动下载及部分机型无线传输；
[OI.Share](https://software.omsystem.com/oishare/en/) 和
[RAW 传输问答](https://support.jp.omsystem.com/en/support/imsg/digicamera/qa/products/oishare/index03.html)
说明官方手机工作流。它们不是公开 SDK 文档。
本轮未查到可供 RawLab 直接接入的通用官方开发接口，后续应查合作申请或可合法复用的协议实现。

### RICOH / PENTAX 与 THETA

[RICOH 官方历史新闻索引](https://news.ricoh-imaging.co.jp/rim_info2/event-service/index_6.html)
保留 2018 年四种相机 SDK 发布记录，历史入口是 `api.ricoh/products/camera-sdk/`。
本次该入口未能取得有效当前页面。历史官方文档的
[Camera USB SDK 图像处理文档](https://ricohapi.github.io/docs/camera-usb-sdk-cpp/image-handling/) 和
[Wireless SDK for iOS 图像处理文档](https://ricohapi.github.io/docs/camera-wireless-sdk-ios/image-handling/)
仍有检索索引留存，但本次最终直连核对均为 HTTP 404；Android 对应图像处理页也未能读取。
因此保留“曾有官方无线 SDK”的结论，不把旧索引中的方法说明当作当前可获得的接口合同。
后续必须重新取得可用规格、支持型号和分发条款，确认既有图片/原始 RAW 能力；不能直接套给 GR。

THETA 有独立的 [开发者入口](https://docs.ricoh360.com/) 和
[官方 API 规格仓库](https://github.com/ricohapi/theta-api-specs)，面向全景相机；
它不证明普通 RICOH GR 或 PENTAX DSLR 使用相同接口。

### Leica 与 Hasselblad

[Leica FOTOS](https://leica-camera.com/en-US/photography/leica-apps/leica-fotos) 明确包含 DNG 传输；
[Capture One 合作公告](https://leica-camera.com/en-US/press/leica-camera-ag-announces-strategic-partnership-with-capture-one)
说明存在合作集成。两者都不能当作通用公开 API。

[Hasselblad A6D 手册](https://cdn.hasselblad.com/manuals/A6D_User_Manual/1.0.0/A6D_User_Manual_EN.pdf)
提到可申请 Windows Phocus SDK，范围是特定航空设备；
[Phocus Mobile](https://www.hasselblad.com/phocus/phocus-mobile-2/) 的 Wi-Fi/RAW 能力是官方 App 能力。
两家均应先取得明确开发入口，不能从商用应用“已经支持”倒推可以复制协议或直接分发 SDK。

### SIGMA 与 Phase One

SIGMA 的 [SDK 发布说明](https://www.sigma-global.com/en/news/2020/07/02/10916/) 明确是电脑经 USB 控制 fp，
[官方资源目录](https://www.sigma-global.com/jp/support/catalog/) 仍列 SDK 下载。
这不能推导 X3F 设备或后续型号有 Wi-Fi 接口；本次未核实通用无线 SDK。

Phase One 的 [SDK 文档](https://developer.phaseone.com/sdk/index.html) 列 Windows/Linux 和具体相机系列，
[功能表](https://developer.phaseone.com/sdk/docs/3_feature_overview/index.html) 明确区分新拍订阅与
Image Browsing：后者可列存储、取预览/元数据、下载整个 IIQ。
[传输说明](https://developer.phaseone.com/sdk/docs/6_camerasdk_features/subs-full-image.html) 提到 Wi-Fi 慢链路，
仍需具体机型、网络设置、许可和目标系统验证，不扩大成所有 Phase One 或四端无线支持。

### GoPro、DJI、Insta360

- [Open GoPro](https://gopro.com/en/us/info/open-gopro) 明确支持 SD 卡媒体传输并公开 API；
  [官方文档](https://gopro.github.io/OpenGoPro/docs/) 应用于核对型号、配对、媒体列表和下载。
  BLE 控制/唤醒与 Wi-Fi 文件传输分别建模，不把能连接蓝牙当作能传照片。
- [DJI MSDK 介绍](https://developer.dji.com/doc/mobile-sdk-tutorial/en/basic-introduction/msdk-introduction.html) 和
  [MediaManager](https://developer.dji.com/iframe/mobile-sdk-doc/android/reference/dji/sdk/camera/DJIMediaManager.html)
  有已保存媒体下载接口；[旧硬件支持表](https://developer.dji.com/mobile-sdk/documentation/introduction/product_introduction.html)
  不能代表现售 Osmo Action/Pocket。还需区分 API 代际和飞机/手持产品，不为读取普通相机照片引入无关飞控能力。
- [Insta360 SDK 申请](https://onlinemanual.insta360.com/developer/en-us/resource/sdk)、
  [连接方式](https://onlinemanual.insta360.com/developer/en-us/resource/integration)、
  [相机文件 API](https://insta360develop.github.io/Insta360-Developer_Docs/en/x/desktop/camera/)
  确认文件列表/下载和平台连接差异。OSC 是 Wi-Fi 候选路线，但其机型、命令、原图能力需另验；
  成功下载 INSP/INSV 不等于 RawLab 能处理它们，本期不扩展全景拼接与视频能力。

## 4. 对后续产品范围的建议

这些是调研优先级，不是开发排期或已经批准的范围：

1. 完成 Sony 的协议、持久文件和能力合同。品牌无关部分只共享确实相同的下载/导入语义。
2. 传统相机下一轮优先核实 Canon CCAPI：公开功能定义最直接对应卡内浏览与下载，但先解决实际地区的许可与目标机型。
3. Fujifilm、Nikon、RICOH/PENTAX 在取得具体资料后比较覆盖面；不要按“已有 SDK”给出相同实现成本。
4. GoPro/THETA/Insta360 若有明确用户需求可独立推进；接口较开放不等于优先于摄影用户需要的 RAW 相机。
5. 未开放公共接口的品牌保留明确的外部中转导入；接收用户用官方软件保存的文件，不读取其私有数据库、账号或凭据。

FTP/FTPS、PTP/IP、HTTP 都只是传输基础。不同品牌的配对、认证、对象格式、命令扩展与事件生命周期仍可能不同。
可复用传输合同，不承诺一个“通用 PTP 驱动”覆盖全部相机。

## 5. 下一次调研的完成标准

每个准备实施的品牌至少取得：当前接口版本与许可、具体样机/固件、平台和无线接口矩阵、已有文件枚举、
原始 RAW 与 JPEG 的数据对照、认证流程、恢复语义、SDK 分发方式及 RawLab 格式支持结果。
只有完成真机与目标平台闭环后才登记兼容；官方支持名单、样例编译通过或第三方应用宣传均不能替代。

本文件不保存个人联系方式、相机序列号、下载账号和受限开发包；供应商页面更新时保留旧结论的日期，并重新核实受影响项。
