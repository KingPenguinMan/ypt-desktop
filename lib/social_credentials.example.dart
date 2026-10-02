/// 第三方登录凭证（**本文件不纳入版本控制**）。
///
/// 为什么单独拆出来：
///   这些 clientId / clientSecret 来自官方 App 的逆向分析，是**第三方服务
///   的凭证**，不属于本项目。把它们写进公开仓库等于替别人泄露凭证。
///
/// 首次构建前：
///   cp lib/social_credentials.example.dart lib/social_credentials.dart
///   然后把下面的占位值换成真实值。
///
/// 本文件已在 .gitignore 中，不会被提交。改动后可用
///   git check-ignore -v lib/social_credentials.dart
/// 确认忽略规则生效。
class SocialCredentials {
  SocialCredentials._();

  /// Kakao REST API key（同时用作自定义 scheme 的一部分）。
  static const String kakaoClientId = 'PUT_YOUR_KAKAO_REST_API_KEY_HERE';

  /// Naver OAuth client id。
  static const String naverClientId = 'PUT_YOUR_NAVER_CLIENT_ID_HERE';

  /// Naver OAuth client secret。
  static const String naverClientSecret = 'PUT_YOUR_NAVER_CLIENT_SECRET_HERE';

  /// 三项是否都已填入真实值。
  ///
  /// 未配置时社交登录会在调用处给出明确错误，而不是发出一个注定失败的请求
  /// 让用户对着 401 猜原因。
  static bool get isConfigured =>
      !kakaoClientId.startsWith('PUT_YOUR_') &&
      !naverClientId.startsWith('PUT_YOUR_') &&
      !naverClientSecret.startsWith('PUT_YOUR_');
}
