import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:baidupan/src/error/upload_validation_error.dart';
import 'package:baidupan/src/util/pan_utils.dart';
import 'package:crypto/crypto.dart';

typedef Md5FileConverter = Future<String> Function(String path);

class Md5Utils {
  const Md5Utils._();

  static Md5FileConverter md5Converter = md5FileUseBytes;

  static Future<String> getFileMd5(String filePath,
      [int blockSize = 1024 * 1024]) async {
    return md5Converter(filePath);
  }

  static Future<String> md5FileUseBytes(String filePath,
      [int blockSize = 1024 * 1024]) async {
    final file = File(filePath);
    return (await md5.bind(file.openRead()).first).toString();
  }

  static Future<String> md5FileUseCmd(String path) async {
    final tools = 'md5sum';

    final result = Process.runSync(tools, [path]);
    // 获取输出结果
    final output = result.stdout as String;
    return output.split(' ').first;
  }

  static List<String> getBlockList(
    String filePath, [
    int blockSize = 4 * 1024 * 1024,
  ]) {
    final file = File(filePath);
    final accessFile = file.openSync(mode: FileMode.read);
    final result = <String>[];

    while (true) {
      final block = accessFile.readSync(blockSize);
      if (block.isEmpty) {
        break;
      }
      result.add(md5.convert(block).toString());
    }

    accessFile.closeSync();

    return result;
  }

  // ignore: unused_element
  static Digest _convert(List<int> data) {
    var innerSink = _DigestSink();
    var outerSink = md5.startChunkedConversion(innerSink);
    outerSink.add(data);
    outerSink.close();
    return innerSink.value;
  }

  static String getFileSliceMd5(String localPath, int sliceLength) {
    final file = File(localPath);
    final accessFile = file.openSync(mode: FileMode.read);
    final buffer = accessFile.readSync(sliceLength);
    final result = md5.convert(buffer).toString();
    accessFile.closeSync();
    return result;
  }

  static Future<BaiduMd5Snapshot> getBaiduMd5SnapshotInIsolate({
    required String filePath,
    required int blockSize,
    int sliceLength = 256 * 1024,
  }) async {
    final receivePort = ReceivePort();
    try {
      await Isolate.spawn(
        _calculateBaiduMd5SnapshotEntry,
        [receivePort.sendPort, filePath, blockSize, sliceLength],
      );

      final message = await receivePort.first;
      if (message is Map && message['error'] != null) {
        throw StateError(
          '${message['error']}\n${message['stackTrace'] ?? ''}',
        );
      }
      if (message is List && message.length == 3) {
        return BaiduMd5Snapshot(
          contentMd5: message[0] as String,
          sliceMd5: message[1] as String,
          blockMd5List: (message[2] as List).whereType<String>().toList(),
        );
      }
      throw StateError('Invalid md5 isolate response: $message');
    } finally {
      receivePort.close();
    }
  }

  @pragma('vm:entry-point')
  static void _calculateBaiduMd5SnapshotEntry(List<dynamic> args) {
    final sendPort = args[0] as SendPort;
    final filePath = args[1] as String;
    final blockSize = args[2] as int;
    final sliceLength = args[3] as int;

    try {
      final snapshot = getBaiduMd5SnapshotSync(
        filePath: filePath,
        blockSize: blockSize,
        sliceLength: sliceLength,
      );
      sendPort.send([
        snapshot.contentMd5,
        snapshot.sliceMd5,
        snapshot.blockMd5List,
      ]);
    } catch (error, stackTrace) {
      sendPort.send({
        'error': error.toString(),
        'stackTrace': stackTrace.toString(),
      });
    }
  }

  static BaiduMd5Snapshot getBaiduMd5SnapshotSync({
    required String filePath,
    required int blockSize,
    required int sliceLength,
  }) {
    final file = File(filePath);
    final accessFile = file.openSync(mode: FileMode.read);
    final blockMd5List = <String>[];
    final sliceBytes = BytesBuilder(copy: false);
    final contentDigestSink = _DigestSink();
    final contentSink = md5.startChunkedConversion(contentDigestSink);

    try {
      while (true) {
        final block = accessFile.readSync(blockSize);
        if (block.isEmpty) {
          break;
        }

        contentSink.add(block);
        blockMd5List.add(md5.convert(block).toString());

        final remainingSliceBytes = sliceLength - sliceBytes.length;
        if (remainingSliceBytes > 0) {
          if (block.length <= remainingSliceBytes) {
            sliceBytes.add(block);
          } else {
            sliceBytes.add(block.sublist(0, remainingSliceBytes));
          }
        }
      }
    } finally {
      accessFile.closeSync();
      contentSink.close();
    }

    return BaiduMd5Snapshot(
      contentMd5: contentDigestSink.value.toString(),
      sliceMd5: md5.convert(sliceBytes.takeBytes()).toString(),
      blockMd5List: blockMd5List,
    );
  }
}

class BaiduMd5Snapshot {
  final String contentMd5;
  final String sliceMd5;
  final List<String> blockMd5List;

  const BaiduMd5Snapshot({
    required this.contentMd5,
    required this.sliceMd5,
    required this.blockMd5List,
  });
}

class BaiduMd5 {
  final String filePath;
  final int memberLevel;

  BaiduMd5({
    required this.filePath,
    required this.memberLevel,
  });

  String? _contentMd5;
  String? _sliceMd5;
  List<String>? _blockMd5List;
  Map<String, int>? _fingerprint;

  Future<String> get contentMd5 async {
    await prepareInIsolate();
    return _contentMd5!;
  }

  String get sliceMd5 {
    _prepareSync();
    return _sliceMd5!;
  }

  List<String> get blockMd5List {
    _prepareSync();
    return _blockMd5List!;
  }

  /// 所有摘要必须来自同一次读取；只有文件指纹相符时才复用缓存。
  /// 旧版保存的摘要没有指纹，需要重新计算。
  Future<void> prepareInIsolate() async {
    final before = _readFingerprint();
    if (_hasValidCache(before)) return;
    _clearCache();
    final snapshot = await Md5Utils.getBaiduMd5SnapshotInIsolate(
      filePath: filePath,
      blockSize: PanUtils.getBlockSize(memberLevel),
    );
    _acceptSnapshot(snapshot, before);
  }

  void _prepareSync() {
    final before = _readFingerprint();
    if (_hasValidCache(before)) return;
    _clearCache();
    final snapshot = Md5Utils.getBaiduMd5SnapshotSync(
      filePath: filePath,
      blockSize: PanUtils.getBlockSize(memberLevel),
      sliceLength: 256 * 1024,
    );
    _acceptSnapshot(snapshot, before);
  }

  bool _hasValidCache(Map<String, int> fingerprint) =>
      _contentMd5 != null &&
      _sliceMd5 != null &&
      _blockMd5List != null &&
      _sameFingerprint(_fingerprint, fingerprint);

  void _clearCache() {
    _contentMd5 = null;
    _sliceMd5 = null;
    _blockMd5List = null;
    _fingerprint = null;
  }

  void _acceptSnapshot(
    BaiduMd5Snapshot snapshot,
    Map<String, int> before,
  ) {
    if (!_sameFingerprint(before, _readFingerprint())) {
      _clearCache();
      throw const BaiduUploadValidationException('计算上传摘要时文件发生变化，请稍后重新上传');
    }
    _contentMd5 = snapshot.contentMd5;
    _sliceMd5 = snapshot.sliceMd5;
    _blockMd5List = List<String>.unmodifiable(snapshot.blockMd5List);
    _fingerprint = before;
  }

  Map<String, int> _readFingerprint() {
    final stat = File(filePath).statSync();
    if (stat.type != FileSystemEntityType.file) {
      throw const BaiduUploadValidationException('待上传文件不存在或不是普通文件');
    }
    return {
      'size': stat.size,
      'modifiedMicros': stat.modified.microsecondsSinceEpoch,
      'changedMicros': stat.changed.microsecondsSinceEpoch,
    };
  }

  static bool _sameFingerprint(
    Map<String, int>? before,
    Map<String, int> after,
  ) =>
      before != null &&
      before.length == after.length &&
      after.entries.every((entry) => before[entry.key] == entry.value);

  Map<String, dynamic> toMap() {
    return {
      'filePath': filePath,
      'memberLevel': memberLevel,
      'blockMd5List': _blockMd5List,
      'contentMd5': _contentMd5,
      'sliceMd5': _sliceMd5,
      'fingerprint': _fingerprint,
    };
  }

  factory BaiduMd5.fromMap(Map<String, dynamic> map) {
    final instance = BaiduMd5(
      filePath: map['filePath'],
      memberLevel: map['memberLevel'],
    );
    final blockMd5List = map['blockMd5List'];
    if (blockMd5List is List) {
      instance._blockMd5List = List<String>.unmodifiable(
        blockMd5List.whereType<String>(),
      );
    }
    instance._contentMd5 = map['contentMd5'] as String?;
    instance._sliceMd5 = map['sliceMd5'] as String?;
    final fingerprint = map['fingerprint'];
    if (fingerprint is Map &&
        fingerprint['size'] is int &&
        fingerprint['modifiedMicros'] is int &&
        fingerprint['changedMicros'] is int) {
      instance._fingerprint = {
        'size': fingerprint['size'] as int,
        'modifiedMicros': fingerprint['modifiedMicros'] as int,
        'changedMicros': fingerprint['changedMicros'] as int,
      };
    }
    return instance;
  }
}

class _DigestSink extends Sink<Digest> {
  /// The value added to the sink.
  ///
  /// A value must have been added using [add] before reading the `value`.
  Digest get value => _value!;

  Digest? _value;

  /// Adds [value] to the sink.
  ///
  /// Unlike most sinks, this may only be called once.
  @override
  void add(Digest value) {
    if (_value != null) throw StateError('add may only be called once.');
    _value = value;
  }

  @override
  void close() {
    if (_value == null) throw StateError('add must be called once.');
  }
}
