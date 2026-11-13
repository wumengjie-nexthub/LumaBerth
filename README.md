# 映格（LumaBerth）

Android 与 Windows 的 Flutter 客户端原型。两端直接连接用户自己的 GitHub 私有仓库，共用 Dart 备份队列、远端目录和恢复逻辑。

## 启动

本轮采用 Flutter 3.47.9、Dart 3.13。Android 最低为 Android 11（API 30），开发环境使用 JDK 17 或更高版本、Android SDK 36 和 Flutter 对应的 NDK。Windows 需要 Flutter 支持的 Visual Studio C++ 桌面开发工作负载、Windows SDK，以及插件目录的符号链接支持。

```powershell
flutter pub get
flutter devices
flutter run -d windows
flutter run -d <Android设备ID>
```

首次使用：每位使用者先创建自己的 GitHub App，在映格中填写其 Client ID 和 App 设置页链接，然后复制设备码并前往 GitHub 确认登录。已有授权的私库可以直接选择；新用户可创建照片专用私库（选择 Private 并开启 Add a README），再在 GitHub 选择 Only select repositories，仅授权该私库。回到应用确认账号和库名，点「确认使用」即进入相册首页。

映格默认不内置项目维护者的 GitHub App。自行创建 App 的步骤见下文；公开标识保存在本机，登录令牌另存于设备安全存储中。已有版本绑定的仓库和令牌不会因更新自动删除；需要重新授权时，请填写你自己的 GitHub App。

旧版用户如果想改用自己的 App，可在「设置」中选择「断开 GitHub」，再用自己的 App 连接原来的私库。断开不会删除仓库中的照片，但会关闭自动备份；重新连接后请按需重新开启。

## 隐私与授权

映格使用登录用户的 GitHub 授权，将原图、缩略图和目录直接写入所选仓库；当前客户端不通过项目维护者的服务器中转照片。登录令牌保存在使用者设备的安全存储中。

- 应用请求的 `Contents: Read and write` 是整个获授权仓库的内容读写权限，并非只限相册目录。安装时请选择 `Only select repositories`，并仅授权照片专用私库。
- 原图没有经过端到端加密。GitHub、获授权的仓库访问者，以及能够使用 GitHub App 私钥获取安装令牌的 App 管理者，都可能访问授权范围内的内容。
- 在应用中断开账号会清除本机登录信息，不会删除远端照片，也不会自动卸载 GitHub 上的 App。如需撤销访问，请在 GitHub 的已安装 App 和已授权 App 设置中分别检查并撤销。
- 源码仓库可以公开，照片仓库应保持独立且私有。将照片仓库改为公开会暴露其中的目录和 Release 附件。公开源码前也应检查提交历史和 Actions 日志中的照片、令牌及密钥。

## 创建自己的 GitHub App

每位使用者自行注册并管理 GitHub App，不需要运行自己的服务器：

1. 打开映格，点「连接我的 GitHub」→「开始设置」→「打开 GitHub 创建页面」。页面会预填 App 名称、主页、私有可见范围、关闭 Webhook 和仓库 `Contents: Read and write` 权限；如名称被占用，可以换一个。GitHub 仍允许用户修改这些设置。
2. 在 GitHub 的 `Identifying and authorizing users` 区域勾选 `Enable Device Flow`，保留用户授权令牌过期设置，滑到页面底部点 `Create GitHub App`。GitHub 文档没有列出设备授权的预填参数，因此这一步仍需手动操作。
3. 创建后回到映格，点「我已创建，继续」。从 GitHub 的 App 设置页复制 **Client ID** 和浏览器地址栏中的设置页链接 `https://github.com/settings/apps/<slug>`，分别填入映格。也可填写 `https://github.com/apps/<slug>` 或链接末尾的名称。映格会先确认这个名称对应一个真实存在的 App，再发起设备授权。
4. Client ID 不是 App ID；这些是公开标识，不要向映格输入 Client secret、App 私钥或访问令牌。点「保存并继续」，然后按提示完成设备码登录。
5. 在 GitHub 安装自己的 App 时，仅选择照片专用私库；回到映格确认仓库。已创建过 App 的用户也可以在引导首页直接选择「我已经创建过 GitHub App」。

注册界面的字段说明可参考 [GitHub 官方文档](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)。

开发者也可在自行构建时同时传入 `--dart-define=GITHUB_CLIENT_ID=你的ClientID` 和 `--dart-define=GITHUB_APP_SLUG=你的slug`。普通安装包不需要这些参数，由使用者在应用中填写即可。

## 安装与打包

Android 11 及以上使用通用 APK，64 位 Windows 使用 Setup.exe。历史 [GitHub Releases](https://github.com/wumengjie-nexthub/LumaBerth/releases/latest) 可能仍使用旧的共享 App；支持应用内自行配置的版本以新安装包为准。

Android 正式包在运行 `flutter build apk --release` 前需要设置 `LUMABERTH_KEYSTORE`（PKCS12 密钥库的绝对路径）和 `LUMABERTH_SIGNING_PASSWORD`（密钥库和别名 `lumaberth` 的密码）。后续更新须复用同一签名密钥并递增 `pubspec.yaml` 中的构建号。官方签名证书 SHA-256 为 `6274ecef5d05b6b6b07fa28f16d74e30799f425d37fca3ab1851bbcd145d06e9`，可用 Android SDK 的 `apksigner verify --print-certs` 核对。自行构建可使用自己的签名。

Windows 在 `flutter build windows --release` 后，用 Inno Setup 7 编译 `windows/installer.iss`。传入 `/DAppVersion=版本号` 和 `/DVCRedistDir=当前 MSVC 版本的 x64 Microsoft.VC*.CRT 目录`。产物位于 `build/dist`，包含 Flutter 数据、插件和 Visual C++ 运行库，按当前用户安装。

## 使用

- **Android**　手动导入使用系统照片选择器，也提供系统文件选择器读取原件。系统照片选择器可能按用户授权隐去位置元数据。自动发现使用 MediaStore，需要完整照片权限。每个存储卷独立保存备份起点和扫描进度。相机稍后写完的新照片会在后续扫描入队；拔卡保留进度，首次遇到的新卷从当时开始扫描。开启时可选「从现在开始」，或先查看已有照片的数量和大小再加入队列。WorkManager 在网络和电量条件满足时执行。
- **Windows**　选择本机文件导入，点击缩略图查看详情或下载原图。勾选多张照片后可批量导出到一个目录，同名文件自动编号。Windows Imaging Component 从原文件生成缩略图，HEIC 等格式需要系统安装对应解码器。退出程序保留队列，下次打开继续。
- **两端**　相册按时间浏览并按需加载缩略图。备份保留静态文件，原图大小和 SHA-256 校验成功、缩略图上传成功、目录写入成功后才显示「已备份」。来源删除和断开账号均保留远端备份。云端删除在照片详情中单独确认，未完成的删除保存在本机待继续。

## 跨端目录 v1

默认分支的索引路径为 `photo-album/v1/<UUID前两位>/<照片UUID>.json`。每张静态照片占用一个固定的批次路径。内容为 UTF-8 JSON，结构如下。

```json
{
  "version": 1,
  "photos": [{
    "id": "91697e4a-f611-466b-b7f0-ed2b17a3a544",
    "name": "旅行.heic",
    "takenAt": "2026-11-11T00:00:00.000Z",
    "size": 123456,
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "original": 101,
    "thumbnail": 102
  }]
}
```

确认云端删除时，客户端按目录文件当前的 Git blob SHA 将该路径更新为 `{"version":1,"photos":[],"deleted":{"id":"照片UUID","original":101,"thumbnail":102}}`，然后删除两个附件。读取端将空批次显示为零张照片；上传端遇到同一照片的删除记录时结束旧任务。请保留该路径，使离线设备也能识别删除。

示例中的大小、摘要和附件 ID 仅说明字段类型。时间使用 UTC，优先取可读取的拍摄时间，缺失时使用已知文件时间或导入时间。`original`、`thumbnail` 是对应仓库里的 GitHub Release asset ID。恢复端从默认分支读取目录，以这两个 ID 读取资源。

每次安装使用独立的设备 UUID，Release 标签为 `photo-album-<设备UUID>-<组号>`，组号从 1 开始。附件名为 `<照片UUID>.original` 与 `<照片UUID>.thumb.jpg`。写入按实际附件数预留两个位置，响应丢失时按稳定名称核对已有附件。不同设备导入的相同字节也保留各自的照片记录和原文件名。

## 定向验证

```powershell
flutter test test/backup_test.dart test/media_scan_test.dart test/connection_view_test.dart test/album_view_test.dart
```

备份测试使用临时 SQLite 数据库和模拟 GitHub 接口，覆盖中断、摘要不符、换组、目录恢复、限流、下载及删除。界面测试覆盖 360 与 1280 像素宽度的首次连接流程（含自填 App、App 名称校验与错误提示），以及 320 与 1280 像素宽度的相册网格、照片详情与备份队列。

真实 GitHub App 授权、Android 相册授权与锁屏调度、HEIC 原件元数据，以及 Android ↔ Windows 的双向恢复仍需实机验收。可用一张测试照片做双向恢复，分别比对源文件和另一端导出文件的大小与 SHA-256。
