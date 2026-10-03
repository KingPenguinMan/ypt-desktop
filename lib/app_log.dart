import 'dart:io';

import 'package:flutter/foundation.dart';

/// 极简文件日志。
///
/// 存在的理由很具体：Windows release 版的 Flutter GUI 程序没有控制台，
/// `debugPrint` 的输出**无处可去**。托盘初始化失败时（TrayIcon.create()
/// 返回 null、setIcon 抛异常、setVisible 返回 false……）用户和我都看不到
/// 任何线索，只能靠猜。
///
/// 日志写到 `%LOCALAPPDATA%\ypt_client\ypt.log`，位置稳定且通常可写。
/// 实在拿不到该环境变量时退到系统临时目录。
class AppLog {
  AppLog._();

  static File? _file;
  static bool _initialized = false;

  /// 单条日志长度上限，避免异常消息过长污染文件。
  static const int _maxLine = 2000;

  static File? _resolveFile() {
    try {
      final base =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['TEMP'] ??
          Directory.systemTemp.path;
      final dir = Directory('$base${Platform.pathSeparator}ypt_client');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return File('${dir.path}${Platform.pathSeparator}ypt.log');
    } catch (_) {
      return null;
    }
  }

  static void init() {
    if (_initialized) return;
    _initialized = true;
    _file = _resolveFile();
    _rotateIfLarge();
  }

  /// 超过 512 KB 就截断重来，避免无限增长。
  static void _rotateIfLarge() {
    final f = _file;
    if (f == null) return;
    try {
      if (f.existsSync() && f.lengthSync() > 512 * 1024) {
        f.writeAsStringSync('', flush: true);
      }
    } catch (_) {}
  }

  /// 写一行。任何失败都吞掉——日志本身绝不能影响主流程。
  static void log(String message) {
    init();
    final line = '[${_stamp()}] $message';
    // 同时走 debugPrint：在 `flutter run` 下能看到，release 下无害。
    debugPrint(line);
    final f = _file;
    if (f == null) return;
    try {
      final text = line.length > _maxLine ? line.substring(0, _maxLine) : line;
      f.writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// 记录"某一步执行结果"，用来定位失败发生在哪一环。
  static void step(String name, Object? result) {
    log('STEP $name -> $result');
  }

  /// 记录异常（含堆栈）。
  static void error(String where, Object e, [StackTrace? st]) {
    log('ERROR $where: $e');
    if (st != null) log('  at $st');
  }

  /// 供用户直接查看日志位置。
  static String get path => _file?.path ?? '(unavailable)';

  static String _stamp() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}.'
        '${three(d.millisecond)}';
  }
}
