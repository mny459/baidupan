import 'dart:io';

import '../error/upload_validation_error.dart';
import 'md5_utils.dart';
import 'pan_utils.dart';

/// 一个上传任务私有的文件副本。预上传、切片、合并和重试均读取此副本。
///
/// 原文件在快照完成后继续变化，不会改变正在上传的内容。
class BaiduUploadSnapshot {
  BaiduUploadSnapshot._({
    required this.path,
    required this.size,
    required this.memberLevel,
    required this.modifiedTime,
    required this.md5,
    required Directory directory,
    required FileStat fingerprint,
  })  : _directory = directory,
        _fingerprint = fingerprint;

  final String path;
  final int size;
  final int memberLevel;
  final DateTime modifiedTime;
  final BaiduMd5 md5;
  final Directory _directory;
  final FileStat _fingerprint;
  bool _disposed = false;

  static Future<BaiduUploadSnapshot> create({
    required String localPath,
    required int memberLevel,
  }) async {
    final source = File(localPath);
    final before = await source.stat();
    if (before.type != FileSystemEntityType.file) {
      throw const BaiduUploadValidationException('待上传文件不存在或不是普通文件');
    }
    PanUtils.validateUploadSize(before.size, memberLevel);

    final directory = await Directory.systemTemp.createTemp('baidupan-upload-');
    try {
      final copy = await source.copy(
        '${directory.path}${Platform.pathSeparator}upload.bin',
      );
      final after = await source.stat();
      final copyStat = await copy.stat();
      if (!_sameFileState(before, after) || copyStat.size != before.size) {
        throw const BaiduUploadValidationException('复制上传文件时原文件发生变化，请稍后重新上传');
      }
      final md5 = BaiduMd5(filePath: copy.path, memberLevel: memberLevel);
      await md5.prepareInIsolate();
      PanUtils.validateBlockMd5List(
        fileSize: before.size,
        memberLevel: memberLevel,
        blockMd5List: md5.blockMd5List,
      );
      final snapshot = BaiduUploadSnapshot._(
        path: copy.path,
        size: before.size,
        memberLevel: memberLevel,
        modifiedTime: before.modified,
        md5: md5,
        directory: directory,
        fingerprint: copyStat,
      );
      snapshot.validateUnchanged();
      return snapshot;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  void validateUnchanged() {
    if (_disposed || !_sameFileState(_fingerprint, File(path).statSync())) {
      throw const BaiduUploadValidationException('上传文件快照发生变化，请重新上传');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (await _directory.exists()) {
      await _directory.delete(recursive: true);
    }
  }

  static bool _sameFileState(FileStat before, FileStat after) =>
      before.type == FileSystemEntityType.file &&
      after.type == FileSystemEntityType.file &&
      before.size == after.size &&
      before.modified == after.modified &&
      before.changed == after.changed;
}
