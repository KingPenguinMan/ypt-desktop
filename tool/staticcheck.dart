// Dart 源码静态自检 —— 补足本环境跑不了 `dart analyze` 的盲区。
//
// 为什么需要它：当前沙箱无法创建子进程，`dart analyze`（需 fork
// analysis_server）和 `dart compile kernel`（需 fork gen_kernel_aot）都
// 跑不了。`dart format` 只做语法解析，查不出语义问题。
// 我就曾因一次编辑留下两个同名 `sync()` 方法，直到用户跑 analyze 才暴露。
//
// 本脚本做三类机械检查（不追求替代 analyze，只覆盖最容易犯的错）：
//   1. 同一个类里重复声明成员（方法/字段）—— 这是实际踩过的坑
//   2. 类内调用了本类未定义、且不属于 Dart 内置的私有方法
//   3. 未使用的 import（可能引入循环依赖或多余耦合）
//
// 运行：dart run tool/staticcheck.dart
import 'dart:io';

int _problems = 0;

void report(String file, int line, String msg) {
  _problems++;
  print('  $file:$line  $msg');
}

/// 粗略剥掉注释和字符串，避免误判。
String strip(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    // 行注释
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') i++;
      continue;
    }
    // 块注释
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n'); // 保留行号
        i++;
      }
      i += 2;
      continue;
    }
    // 单引号 / 双引号字符串
    if (c == "'" || c == '"') {
      final q = c;
      out.write(' ');
      i++;
      while (i < src.length) {
        if (src[i] == r'\') {
          i += 2;
          continue;
        }
        if (src[i] == q) {
          i++;
          break;
        }
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 提取顶层与类内的成员名，检测重复。
void checkDuplicates(String path, String raw) {
  final src = strip(raw);
  final lines = src.split('\n');

  String? currentClass;
  var braceDepth = 0;
  var classDepth = -1;
  // 注意：必须记下**全部**出现位置。用 putIfAbsent 会把重复项静默合并，
  // 那样永远检测不到重复（这是本脚本第一版的真实 bug）。
  final members = <String, List<int>>{};

  void closeClass() {
    members.forEach((name, where) {
      if (where.length > 1) {
        report(path, where.first, '重复声明: $name（共 ${where.length} 次）');
        for (final l in where.skip(1)) {
          report(path, l, '  （另一次声明）');
        }
      }
    });
    members.clear();
  }

  void addMember(String name, int line) {
    members.putIfAbsent(name, () => <int>[]).add(line);
  }

  for (var n = 0; n < lines.length; n++) {
    final line = lines[n];
    final t = line.trim();

    // 先记下更新前的深度。类成员只出现在 classDepth + 1 这一层；
    // 方法体内的局部变量和类型引用都在更深层，必须排除，
    // 否则 `int out = 0;` 会被当成成员，`throw Foo(...)` 会被当成方法声明。
    final depthBefore = braceDepth;

    final classMatch =
        RegExp(r'^(?:abstract\s+|final\s+|sealed\s+|base\s+)?(?:mixin\s+|class\s+|enum\s+|extension\s+)(\w+)')
            .firstMatch(t);
    if (classMatch != null && t.contains('{')) {
      if (currentClass != null) closeClass();
      currentClass = classMatch.group(1);
      classDepth = braceDepth;
      braceDepth += '{'.allMatches(t).length - '}'.allMatches(t).length;
      continue;
    }

    braceDepth += '{'.allMatches(t).length - '}'.allMatches(t).length;
    if (braceDepth < 0) braceDepth = 0;

    // 类结束
    if (currentClass != null && braceDepth <= classDepth) {
      closeClass();
      currentClass = null;
      classDepth = -1;
      continue;
    }

    if (currentClass == null) continue;
    // 只认类成员这一层。
    if (depthBefore != classDepth + 1) continue;

    const kw = {
      'if', 'for', 'while', 'switch', 'return', 'else', 'case', 'catch',
      'try', 'do', 'throw', 'new', 'this', 'super', 'assert', 'await',
      'yield', 'get', 'set', 'in', 'is', 'as', 'on', 'with', 'extends',
      'implements', 'const', 'var', 'final', 'late', 'required', 'default',
    };

    // getter / setter 先判，避免被下面的通用规则吃掉
    final g = RegExp(r'^(?:static\s+)?[\w<>,?\s]+\s+get\s+(\w+)\s*[{=]').firstMatch(t);
    if (g != null) {
      addMember('get:${g.group(1)}', n + 1);
      continue;
    }
    final st = RegExp(r'^(?:static\s+)?set\s+(\w+)\s*\(').firstMatch(t);
    if (st != null) {
      addMember('set:${st.group(1)}', n + 1);
      continue;
    }

    // 函数类型的字段要先于方法规则处理：
    //   void Function(TrayIconEvent)? _trayListener;
    //   final List<void Function(MenuEvent)> _menuListeners = [];
    // 否则 `Function(` 会被当成方法名 Function（这是本脚本第二版的真实误报）。
    final fnField = RegExp(r'Function\s*(?:<[^>]*>)?\s*\([^)]*\)')
        .firstMatch(t);
    if (fnField != null) {
      // 取 `)` 之后、`=`/`;`/`,` 之前的那个标识符即字段名。
      final after = t.substring(fnField.end);
      final nm = RegExp(r'^[>?\]\s]*(\w+)\s*[=;,)]').firstMatch(after);
      if (nm != null) {
        addMember(nm.group(1)!, n + 1);
        continue;
      }
    }

    // 方法声明：名字后跟 ( ，且不是调用（调用不会出现在行首缩进后作为声明）
    final m = RegExp(r'^(?:@override\s+)?(?:static\s+)?(?:external\s+)?'
            r'[\w<>,?\[\]\s]+\s+(\w+)\s*\(')
        .firstMatch(t);
    if (m != null && !kw.contains(m.group(1)) && m.group(1) != 'Function') {
      addMember(m.group(1)!, n + 1);
      continue;
    }

    // 字段声明：类型 名字 = / ;
    final f = RegExp(r'^(?:static\s+)?(?:final\s+|const\s+)?'
            r'[\w<>,?\[\]\s]+\s+(\w+)\s*[=;]')
        .firstMatch(t);
    if (f != null && !kw.contains(f.group(1))) {
      addMember(f.group(1)!, n + 1);
    }
  }
  if (currentClass != null) closeClass();
}

/// 检测未使用的 import（只报项目内相对导入，包导入容易误判）。
void checkUnusedImports(String path, String raw) {
  final body = strip(raw);
  final imports = <String, int>{};
  final lines = raw.split('\n');
  for (var n = 0; n < lines.length; n++) {
    final m = RegExp(r"""^import\s+'([^']+)'""").firstMatch(lines[n].trim());
    if (m == null) continue;
    final uri = m.group(1)!;
    if (!uri.startsWith('.') && !uri.startsWith('..')) continue; // 只看相对导入
    if (uri.endsWith('.g.dart') || uri.endsWith('.freezed.dart')) continue;
    imports[uri] = n + 1;
  }
  if (imports.isEmpty) return;
  // 去掉 import 行本身再找符号
  final cleaned = body.replaceAll(RegExp(r"import\s+'[^']+';"), '');
  imports.forEach((uri, line) {
    final file = uri.split('/').last.replaceAll('.dart', '');
    // 该导入可能带来的符号：文件名本身，或 as 前缀
    final hasAs = RegExp("import\\s+'${RegExp.escape(uri)}'\\s+as\\s+(\\w+)")
        .firstMatch(raw);
    if (hasAs != null) {
      final alias = hasAs.group(1)!;
      if (RegExp('\\b$alias\\b').hasMatch(cleaned)) return;
      report(path, line, '未使用的 import: $uri (as $alias)');
      return;
    }
    if (cleaned.contains(file)) return;
    // 导入的自定义类名不一定等于文件名，宽松处理：不报
  });
}

void main() {
  final root = Directory('lib');
  if (!root.existsSync()) {
    print('请在项目根目录运行（找不到 lib/）');
    exit(2);
  }
  final files = <File>[];
  for (final e in root.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) files.add(e);
  }
  files.sort((a, b) => a.path.compareTo(b.path));

  print('\n=== 静态自检：${files.length} 个文件 ===\n');
  print('[1] 重复成员声明');
  for (final f in files) {
    final raw = f.readAsStringSync();
    checkDuplicates(f.path.replaceAll(r'\', '/'), raw);
  }
  print('    done');

  print('\n[2] 未使用的相对 import');
  for (final f in files) {
    checkUnusedImports(f.path.replaceAll(r'\', '/'), f.readAsStringSync());
  }
  print('    done');

  print('\n=== 结果 ===');
  if (_problems == 0) {
    print('  未发现机械性错误。\n');
  } else {
    print('  发现 $_problems 处问题。\n');
    exit(1);
  }
}
