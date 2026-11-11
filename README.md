# LumaBerth · 泊光相册

Android 与 Windows 的 Flutter 客户端原型。两端直接连接用户自己的 GitHub 私有仓库，共用 Dart 备份队列、远端目录和恢复逻辑。

## 启动

本轮采用 Flutter 3.47.9、Dart 3.13。Android 最低为 Android 11（API 30），开发环境使用 JDK 17 或更高版本、Android SDK 36 和 Flutter 对应的 NDK。Windows 需要 Flutter 支持的 Visual Studio C++ 桌面开发工作负载、Windows SDK，以及插件目录的符号链接支持。

```powershell
flutter pub get
flutter devices
flutter run -d windows
flutter run -d <Android设备ID>
```

首次使用：点「连接我的 GitHub」，在应用中复制设备码并前往 GitHub 确认登录。已有授权的私库可以直接选择；新用户可创建照片专用私库（选择 Private 并开启 Add a README），再在 GitHub 选择 Only select repositories，仅授权该私库。回到应用确认账号和库名，点「确认使用」即进入相册首页。安卓用户可在首页选择照片或备份手机已有照片，确认数量和大小后才加入队列；自动备份新照片可以单独开启。

发行版默认使用 [LumaBerth GitHub App](https://github.com/apps/lumaberth)（所有者 `suikiiovo`）。从此版本源码运行 `flutter build apk --release` 或 `flutter build windows --release` 即会带上正式 App 的公开标识。使用者登录自己的 GitHub 并选择授权的私库即可。打包 Windows 版时请分发整个 Release 输出目录，正式发布 Android 版前请配置长期使用的签名密钥（项目当前默认使用调试签名）。

需要使用自己的 GitHub App 时，注册并开启 Device Flow 和过期用户令牌，授予 Contents 读写权限，然后同时传入 `--dart-define=GITHUB_CLIENT_ID=你的公开ClientID` 与 `--dart-define=GITHUB_APP_SLUG=你的安装名`。GitHub Actions 也支持同名仓库变量，两项都留空时使用正式 App。

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
flutter test test/backup_test.dart test/media_scan_test.dart test/connection_view_test.dart
```

备份测试使用临时 SQLite 数据库和模拟 GitHub 接口，覆盖中断、摘要不符、换组、目录恢复、限流、下载及删除。界面测试覆盖 360 与 1280 像素宽度的首次连接流程。

真实 GitHub App 授权、Android 相册授权与锁屏调度、HEIC 原件元数据，以及 Android ↔ Windows 的双向恢复仍需实机验收。可用一张测试照片做双向恢复，分别比对源文件和另一端导出文件的大小与 SHA-256。
