import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
  await setupCaCerts(); // Windows TLS 루트 보완 (웹/기타 플랫폼은 no-op)
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
  /// 供 dispose 时对称移除监听。ChangeNotifier 不持有监听者，
  /// 若不移除，AppState 会一直回调已销毁的托盘。
  VoidCallback? _traySync;

  @override
  void initState() {
    super.initState();
    // 托盘菜单要用到 user/科目，登录前建没有内容，所以等首帧之后再建。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final app = context.read<AppState>();
      if (_tray != null) return;
      final tray = TrayService(app);
      _tray = tray;
      await tray.init();
      if (!mounted) {
        // init 期间 widget 可能已被销毁。
        tray.dispose();
        _tray = null;
        return;
      }
      // AppState 每次 notify 都同步托盘菜单（状态行、开始/停止项、空档入口）。
      _traySync = tray.sync;
      app.addListener(_traySync!);
    });
  }

  @override
  void dispose() {
    // AppState 由 Provider 创建，会自行 dispose；这里只清理托盘侧。
    _traySync = null;
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          margin: EdgeInsets.zero,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: kCard,
          indicatorColor: kBrand.withValues(alpha: 0.18),
          labelTextStyle: WidgetStateProperty.all(
              const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
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

