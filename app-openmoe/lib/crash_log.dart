import 'dart:io';

/// Append an error report to %USERPROFILE%\OpenMoe\logs\openmoe-crash.log.
///
/// The library isolate can crash hard (a native fault kills the process
/// before any dialog can render), so everything we *can* catch gets written
/// here first; SetupPage surfaces the tail of the log on next launch.
Future<void> appendCrashLog(String what) async {
  try {
    final home = Platform.environment['USERPROFILE'];
    final dir = Directory(
      home == null ? r'OpenMoe\logs' : '$home\\OpenMoe\\logs',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final stamp = DateTime.now().toIso8601String();
    File('${dir.path}\\openmoe-crash.log')
        .writeAsStringSync('$stamp  $what\n\n', mode: FileMode.append);
  } catch (_) {
    // Nothing sensible left to do if even logging fails.
  }
}

/// The full crash log, or null when none exists.
String? readCrashLogTail() {
  try {
    final home = Platform.environment['USERPROFILE'];
    final f = File(
      home == null
          ? r'OpenMoe\logs\openmoe-crash.log'
          : '$home\\OpenMoe\\logs\\openmoe-crash.log',
    );
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  } catch (_) {
    return null;
  }
}
