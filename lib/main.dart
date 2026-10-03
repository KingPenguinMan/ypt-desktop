import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_log.dart';
import 'app_state.dart';
import 'ca_setup.dart';
import 'tray_service.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

// YPT 브랜드 컬러
const kBrand = Color(0xFFE8552D); // 주황빨강
const kBg = Color(0xFF0D0D0F);
const kCard = Color(0xFF18181B);
const kCard2 = Color(0xFF222227);

///托盘服务实例。由 [_YptAppState] 在启动时创建。
///
/// 之所以不放在 main() 里：托盘需要和 AppState 双向联动（状态变化时刷新
/// 菜单，用户点菜单时操作 AppState），必须在 widget 树里有地方持有它。
TrayService? _tray;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.init();
  AppLog.log('===== app 启动 =====');
  AppLog.log('日志文件: ${AppLog.path}');
  await setupCaCerts(); // Windows TLS 루트 보완 (웹/기타 플랫폼은 no-op)
  AppLog.step('setupCaCerts', 'ok');
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..tryAutoLogin(),
      child: const YptApp(),
    ),
  );
}

class YptApp extends StatefulWidget {
  const YptApp({super.key});

  @override
  State<YptApp> createState() => _YptAppState();
}

class _YptAppState extends State<YptApp> {
  /// 持有的 AppState，用于 dispose 时对称移除监听。
  /// ChangeNotifier 自身不持有监听者，不去重会留下悬空回调。
  AppState? _app;

  /// 托盘的两条回调。保留引用是因为 removeListener / 取消订阅需要同一个
  /// 函数对象——写成 `tray.sync` 两次会得到两个不同的闭包，摘不掉。
  VoidCallback? _traySync;
  VoidCallback? _trayTick;

  /// addTickListener 返回的取消函数。
  VoidCallback? _cancelTrayTick;

  @override
  void initState() {
    super.initState();
    // 托盘菜单要用到 user/科目，登录前建没有内容，所以等首帧之后再建。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      AppLog.log('postFrame: 准备初始化托盘 (mounted=$mounted)');
      if (!mounted) return;
      final app = context.read<AppState>();
      if (_tray != null) {
        AppLog.log('postFrame: 已存在托盘实例，跳过');
        return;
      }
      _app = app;
      final tray = TrayService(app);
      _tray = tray;
      await tray.init();
      if (!mounted) {
        // init 期间 widget 可能已被销毁。
        AppLog.log('postFrame: init 后 widget 已销毁，释放托盘');
        tray.dispose();
        _tray = null;
        return;
      }
      // 两条通道，职责不同：
      //   sync     —— AppState 结构变化（开始/停止/切科目/加载完成）时重建菜单
      //   tickSync —— 每秒只刷新状态行文字，避免重建整棵菜单
      // 两者都要注册：计时数字的秒级通知已从 ChangeNotifier 拆到 tick 通道，
      // 只挂 sync 会让托盘上的时间静止不动。
      _traySync = tray.sync;
      _trayTick = tray.tickSync;
      app.addListener(_traySync!);
      _cancelTrayTick = app.addTickListener(_trayTick!);
      AppLog.log('postFrame: 托盘回调已注册');
    });
  }

  @override
  void dispose() {
    // AppState 由 Provider 创建、会自行 dispose；这里只做托盘侧的对称清理。
    final sync = _traySync;
    if (sync != null) _app?.removeListener(sync);
    _cancelTrayTick?.call();
    _traySync = null;
    _trayTick = null;
    _cancelTrayTick = null;
    _app = null;
    _tray?.dispose();
    _tray = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: kBrand,
      brightness: Brightness.dark,
    ).copyWith(surface: kBg);

    return MaterialApp(
      title: 'YPT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: scheme,
        scaffoldBackgroundColor: kBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: kCard,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          margin: EdgeInsets.zero,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: kCard,
          indicatorColor: kBrand.withValues(alpha: 0.18),
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: kCard2,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kBrand, width: 1.5),
          ),
        ),
      ),
      home: Consumer<AppState>(
        builder: (_, st, _) =>
            st.loggedIn ? const HomeScreen() : const LoginScreen(),
      ),
    );
  }
}
