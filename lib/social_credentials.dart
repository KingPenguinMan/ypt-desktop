/// 第三方登录凭证。
///
/// **本文件不含任何凭证值**，值由构建参数注入（`--dart-define`）。
///
/// 为什么不写进文件：
///   这些 clientId / clientSecret 来自官方 App 的逆向分析，是**第三方服务的
///   凭证**，不属于本项目。无论写死在本文件里，还是写在一个"不入库的同名文件"
///   里，都有问题 —— 前者会泄露，后者会让干净克隆因为 import 落空而构建失败。
///   用构建参数注入可以同时避免这两点：仓库里没有值，文件本身始终存在。
///
/// 本地构建时注入：
///   flutter build windows --release \
///     --dart-define=KAKAO_CLIENT_ID=xxx \
///     --dart-define=NAVER_CLIENT_ID=xxx \
///     --dart-define=NAVER_CLIENT_SECRET=xxx
///
/// Windows 上用 `build_and_test.bat` 时，把值填进 `social_credentials.local.bat`
/// （该文件不入库，模板见 `social_credentials.local.bat.example`），脚本会自动读取。
///
/// 不注入也能构建和运行，只是社交登录会提示"未配置"，邮箱密码登录不受影响。
class SocialCredentials {
  SocialCredentials._();

  /// Kakao REST API key（同时用作自定义 scheme 的一部分）。
  static const String kakaoClientId = String.fromEnvironment('KAKAO_CLIENT_ID');

  /// Naver OAuth client id。
  static const String naverClientId = String.fromEnvironment('NAVER_CLIENT_ID');

  /// Naver OAuth client secret。
  static const String naverClientSecret =
      String.fromEnvironment('NAVER_CLIENT_SECRET');

  /// 三项是否都已注入。
  ///
  /// 未注入时社交登录会在调用处给出明确错误，而不是发出一个注定失败的请求
  /// 让用户对着 401 猜原因。
  static bool get isConfigured =>
      kakaoClientId.isNotEmpty &&
      naverClientId.isNotEmpty &&
      naverClientSecret.isNotEmpty;
}
