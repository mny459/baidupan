import 'dart:convert';
import 'dart:io';

import 'package:baidupan/baidupan.dart';

/// 对于上传百度网盘的包装类
///
/// 用于支持续传，在网络出错或上传合成失败的情况下，也可以重新上传
class BaiduUploadHelper with ILogger {
  /// 百度网盘上传的包装类
  ///
  /// [accessToken] 百度网盘的token
  /// [localPath] 本地文件路径
  /// [remotePath] 网盘文件路径
  /// [memberLevel] 百度网盘的用户等级
  BaiduUploadHelper({
    required this.accessToken,
    required String localPath,
    required this.remotePath,
    required this.memberLevel,
    this.totalRetryCount = 10,
    this.onDiagnostic,
    this.preCreateRtype = UploadRenameRtype.overwrite,
    this.mergeRtype = UploadRenameRtype.overwrite,
  })  : localPath = File(localPath).absolute.path,
        lastModified = File(localPath).statSync().modified;

  /// [accessToken] 百度网盘的token
  /// [resumeMap] 续传的map, 一般由 [getSaveProgressMap] 返回
  factory BaiduUploadHelper.resumeFromMap({
    required String accessToken,
    required Map resumeMap,
    void Function(String message)? onDiagnostic,
  }) {
    final helper = BaiduUploadHelper(
      accessToken: accessToken,
      localPath: resumeMap['localPath'],
      remotePath: resumeMap['remotePath'],
      memberLevel: resumeMap['memberLevel'],
      onDiagnostic: onDiagnostic,
      preCreateRtype: UploadRenameRtype.values[
          resumeMap['preCreateRtype'] as int? ??
              UploadRenameRtype.overwrite.index],
      mergeRtype: UploadRenameRtype.values[
          resumeMap['mergeRtype'] as int? ?? UploadRenameRtype.overwrite.index],
    );

    helper.resumeProgressInfo(resumeMap);
    return helper;
  }

  /// [accessToken] 百度网盘的token
  /// [resumeFile] 续传的配置文件，一般来自于 [saveProgressToFile]
  factory BaiduUploadHelper.resumeFromFile({
    required String accessToken,
    required File resumeFile,
    void Function(String message)? onDiagnostic,
  }) {
    final map = json.decode(resumeFile.readAsStringSync());
    return BaiduUploadHelper.resumeFromMap(
      accessToken: accessToken,
      resumeMap: map,
      onDiagnostic: onDiagnostic,
    );
  }

  /// 百度网盘的accessToken
  final String accessToken;

  /// 本地文件的路径， 保存进度的一部分
  final String localPath;

  /// 网盘的路径， 保存进度的一部分
  final String remotePath;

  /// 会员等级： 0 为非会员，1 为普通会员，2 为超级会员， 保存进度的一部分
  final int memberLevel;

  /// 重试次数
  final int totalRetryCount;

  /// 脱敏诊断信息，可由应用记录到同步日志。
  final void Function(String message)? onDiagnostic;

  /// 预上传阶段的同名处理策略
  final UploadRenameRtype preCreateRtype;

  /// 合并创建阶段的同名处理策略
  final UploadRenameRtype mergeRtype;

  /// 上传的文件 md5 值， 保存进度的一部分
  BaiduMd5? _md5;

  BaiduMd5 get md5 {
    _md5 ??= BaiduMd5(
      filePath: localPath,
      memberLevel: memberLevel,
    );

    return _md5!;
  }

  DateTime lastModified;

  BaiduUploadSnapshot? _snapshot;
  int? _lastSnapshotSize;
  Map<String, dynamic>? _savedMd5Map;
  Map<String, dynamic>? _resumeMd5Map;
  bool _resumePending = false;

  bool _isUploading = false;

  /// 是否正在上传
  bool get isUploading => _isUploading;

  String? _uploadId;

  /// 共有多少个文件块
  int totalBlockCount = 0;

  /// uploadCount 已上传的文件块数量，会被保存到 progress 里
  int uploadCount = 0;

  /// 当前上传的文件块数量
  int currentUploadCount = 0;

  /// 文件大小 [File.lengthSync]
  int get fileTotalSize =>
      _snapshot?.size ?? _lastSnapshotSize ?? File(localPath).lengthSync();

  /// 上传的速度，单位为字节/秒
  int uploadSpeed = 0;

  /// 上传的进度, 范围为 0.0 - 1.0
  double getProgress() {
    if (totalBlockCount == 0 || fileTotalSize <= 0) {
      return 0.0;
    }
    // 文件块的总数量
    final blockSize = PanUtils.getBlockSize(memberLevel);

    // 获取已上传的文件块数量，并计算总上传的字节数
    final totalUploadBytes = blockSize * uploadCount;

    final progress = totalUploadBytes / fileTotalSize;

    if (progress > 1.0) {
      return 1.0;
    }

    return progress;
  }

  /// 获取应该被保存的 map
  Map<String, dynamic> getSaveProgressMap() {
    return {
      'uploadId': _uploadId,
      'localPath': localPath,
      'remotePath': remotePath,
      'memberLevel': memberLevel,
      'saveFileLength': fileTotalSize,
      'md5': _savedMd5Map ?? _originalMd5Map(md5),
      'uploadCount': uploadCount,
      'lastModified': lastModified.millisecondsSinceEpoch,
      'preCreateRtype': preCreateRtype.index,
      'mergeRtype': mergeRtype.index,
    };
  }

  /// 恢复上传进度，注意这里还是需要自行调用 [startUpload] 方法
  void resumeProgressInfo(Map progress) {
    if (_isUploading) {
      throw const BaiduUploadValidationException('上传进行中，不能恢复其他上传任务');
    }
    final savedLocalPath = progress['localPath'] as String;
    final savedRemotePath = progress['remotePath'] as String;
    final savedMemberLevel = progress['memberLevel'] as int;
    final savedFileLength = progress['saveFileLength'] as int;
    final lastModifiedMs = progress['lastModified'] as int;
    final sourceStat = File(localPath).statSync();

    if (lastModifiedMs != sourceStat.modified.millisecondsSinceEpoch) {
      throw const BaiduUploadValidationException('修改时间不一致，文件可能已修改，不支持续传');
    }
    if (savedFileLength != sourceStat.size) {
      throw const BaiduUploadValidationException('文件大小不一致，文件可能已修改，不支持续传');
    }
    if (savedLocalPath != localPath || savedRemotePath != remotePath) {
      throw const BaiduUploadValidationException('上传路径与保存的任务不一致，不支持续传');
    }
    if (savedMemberLevel != memberLevel) {
      throw const BaiduUploadValidationException(
          '会员等级与保存的任务不一致，分片大小可能变化，不支持续传');
    }
    PanUtils.validateUploadSize(savedFileLength, memberLevel);

    _uploadId = progress['uploadId'] as String?;
    _resumeMd5Map = Map<String, dynamic>.from(progress['md5'] as Map);
    _md5 = BaiduMd5.fromMap(_resumeMd5Map!);
    _savedMd5Map = _originalMd5Map(_md5!);
    _lastSnapshotSize = savedFileLength;
    lastModified = sourceStat.modified;
    uploadCount = progress['uploadCount'] as int;
    totalBlockCount = PanUtils.validateUploadSize(savedFileLength, memberLevel);
    if (uploadCount < 0 || uploadCount > totalBlockCount) {
      throw const BaiduUploadValidationException('保存的上传进度不合法，请重新上传');
    }
    _resumePending = true;
  }

  Map<String, dynamic> _originalMd5Map(BaiduMd5 value) {
    // 私有快照只存在于本次运行；持久化时保留原路径和摘要。
    // 指纹属于临时副本，不能被用于原文件的摘要缓存验证。
    return Map<String, dynamic>.from(value.toMap())
      ..['filePath'] = localPath
      ..remove('fingerprint');
  }

  void _verifyResumeSnapshot(BaiduUploadSnapshot snapshot) {
    final previous = _resumeMd5Map;
    if (_uploadId == null) return;
    final current = snapshot.md5.toMap();
    final oldBlocks = previous?['blockMd5List'];
    final newBlocks = current['blockMd5List'] as List<String>;
    final matches = previous?['contentMd5'] == current['contentMd5'] &&
        previous?['sliceMd5'] == current['sliceMd5'] &&
        oldBlocks is List &&
        oldBlocks.length == newBlocks.length &&
        List.generate(newBlocks.length, (index) => index)
            .every((index) => oldBlocks[index] == newBlocks[index]);
    if (!matches) {
      _uploadId = null;
      uploadCount = 0;
      throw const BaiduUploadValidationException('文件摘要与保存的上传任务不一致，请重新上传');
    }
  }

  /// 保存进度到文件
  void saveProgressToFile(String filePath) {
    final progress = getSaveProgressMap();
    final text = json.encode(progress);
    final bytes = utf8.encode(text);
    final file = File(filePath);
    if (!file.existsSync()) {
      file.createSync();
    }
    file.writeAsBytesSync(bytes);
  }

  /// 从文件中恢复进度
  void loadProgressFromFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      return;
    }
    final text = file.readAsStringSync();
    final progress = json.decode(text);
    resumeProgressInfo(progress);
  }

  /// 开始上传。一次调用只创建一次文件快照，并在所有重试中复用。
  Future<void> startUpload([UploadHelperListener? uploadHandler]) async {
    if (_isUploading) return;
    _isUploading = true;
    final shouldResume = _resumePending;
    _resumePending = false;
    if (!shouldResume) {
      _uploadId = null;
      _md5 = null;
      _savedMd5Map = null;
      _resumeMd5Map = null;
      _lastSnapshotSize = null;
      uploadCount = 0;
      totalBlockCount = 0;
    }
    currentUploadCount = 0;
    uploadSpeed = 0;

    try {
      uploadHandler?.onUploadStart(this);
      final snapshot = await BaiduUploadSnapshot.create(
        localPath: localPath,
        memberLevel: memberLevel,
      );
      _snapshot = snapshot;
      _md5 = snapshot.md5;
      _lastSnapshotSize = snapshot.size;
      lastModified = snapshot.modifiedTime;
      totalBlockCount = snapshot.md5.blockMd5List.length;
      if (shouldResume) _verifyResumeSnapshot(snapshot);
      _savedMd5Map = _originalMd5Map(snapshot.md5);
      uploadHandler?.onLocalMd5Complete(this);

      final maxAttempts = totalRetryCount < 1 ? 1 : totalRetryCount;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          await _upload(uploadHandler, attempt);
          uploadHandler?.onUploadComplete(this);
          return;
        } catch (error, stackTrace) {
          _notifyError(uploadHandler, error, stackTrace);
          if (!_canRetry(error) || attempt == maxAttempts) rethrow;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    } catch (error, stackTrace) {
      // 请求错误已在循环中通知；快照、续传及回调错误在此通知。
      if (!_reportedErrorIdentical(error)) {
        _diagnoseLocalFailure(error);
        _notifyError(uploadHandler, error, stackTrace);
      }
      rethrow;
    } finally {
      _lastReportedError = null;
      final snapshot = _snapshot;
      _snapshot = null;
      if (snapshot != null) {
        // 任务结束后公开的 md5 再次指向原文件，不能指向即将删除的副本。
        // 保存进度仍使用本任务的固定摘要，由 _savedMd5Map 单独持有。
        _md5 = BaiduMd5.fromMap(_originalMd5Map(snapshot.md5));
      }
      try {
        await snapshot?.dispose();
      } finally {
        _isUploading = false;
      }
    }
  }

  Object? _lastReportedError;

  bool _reportedErrorIdentical(Object error) =>
      identical(_lastReportedError, error);

  void _notifyError(
    UploadHelperListener? uploadHandler,
    Object error,
    StackTrace stackTrace,
  ) {
    _lastReportedError = error;
    if (uploadHandler != null) {
      uploadHandler.onUploadError(this, error, stackTrace);
    } else {
      // HTTP 异常字符串可能包含带 Token 的请求 URL，服务端也可能回显参数。
      final summary = <String, Object?>{
        'event': 'upload_error',
        'errorType': error.runtimeType.toString(),
        if (error is BaiduPanError) ...{
          if (error.responseMap['errno'] is int)
            'errno': error.responseMap['errno'],
          if (error.responseMap['request_id'] is int)
            'request_id': error.responseMap['request_id'],
          'httpStatus': error.response.statusCode,
        },
        if (error is BaiduUploadValidationException)
          'validationMessage': error.message,
      };
      log(json.encode(summary));
    }
  }

  void _diagnoseLocalFailure(Object error) {
    int? size = _snapshot?.size;
    if (size == null) {
      try {
        final stat = File(localPath).statSync();
        if (stat.type == FileSystemEntityType.file) size = stat.size;
      } catch (_) {
        // 读取文件状态也可能失败，诊断只保留已经确定的字段。
      }
    }
    final blockSize = PanUtils.getBlockSize(memberLevel);
    final message = json.encode({
      'stage': 'precreate',
      'event': 'local_validation_error',
      'attempt': 1,
      'rtype': preCreateRtype.index,
      'memberLevel': memberLevel,
      'blockSize': blockSize,
      if (size != null) ...{
        'size': size,
        'blockCount': (size + blockSize - 1) ~/ blockSize,
      },
      'errorType': error.runtimeType.toString(),
      if (error is BaiduUploadValidationException)
        'validationMessage': error.message,
    });
    try {
      if (onDiagnostic != null) {
        onDiagnostic!(message);
      } else {
        log(message);
      }
    } catch (_) {
      // 日志失败不能替换真正的上传错误。
    }
  }

  bool _canRetry(Object error) {
    if (error is BaiduUploadValidationException) return false;
    if (error is BaiduPanError) {
      final errno = error.responseMap['errno'];
      if (errno == 2 || errno == 31023) return false;
    }
    return true;
  }

  Future<void> _upload(
    UploadHelperListener? uploadHandler,
    int attempt,
  ) async {
    final snapshot = _snapshot!;
    snapshot.validateUnchanged();
    final uploader = BaiduPanUploadManager(
      accessToken: accessToken,
      showLog: isShowLog,
      onDiagnostic: onDiagnostic,
    );
    final preCreate = await uploader.preCreate(
      remotePath: remotePath,
      localPath: snapshot.path,
      snapshot: snapshot,
      rtype: preCreateRtype,
      memberLevel: memberLevel,
      uploadid: _uploadId,
      md5: snapshot.md5,
      attempt: attempt,
    );

    if (preCreate.fastUpload) {
      uploadCount = totalBlockCount;
      return;
    }
    final uploadId = preCreate.uploadId;
    if (uploadId == null || uploadId.isEmpty) {
      throw const BaiduUploadValidationException('百度网盘未返回有效的上传任务 ID');
    }
    _uploadId = uploadId;
    final pendingBlocks = preCreate.blockList;
    if (pendingBlocks.toSet().length != pendingBlocks.length ||
        pendingBlocks.any((index) => index < 0 || index >= totalBlockCount)) {
      throw const BaiduUploadValidationException('百度网盘返回的待上传分片索引不合法');
    }
    uploadCount = totalBlockCount - pendingBlocks.length;
    currentUploadCount = 0;
    final stopwatch = Stopwatch()..start();
    var uploadBytes = 0;
    for (final blockIndex in pendingBlocks) {
      snapshot.validateUnchanged();
      final block = await uploader.uploadSinglePart(
        remotePath: remotePath,
        localPath: snapshot.path,
        snapshot: snapshot,
        memberLevel: memberLevel,
        uploadid: uploadId,
        partseq: blockIndex,
      );
      if (block.md5.toLowerCase() != snapshot.md5.blockMd5List[blockIndex]) {
        throw const BaiduUploadValidationException('上传分片的 MD5 与本地快照不一致，请重新上传');
      }
      currentUploadCount++;
      uploadCount++;
      uploadBytes += block.blockSize;
      final elapsedMs = stopwatch.elapsedMilliseconds;
      uploadSpeed = elapsedMs > 0 ? uploadBytes * 1000 ~/ elapsedMs : 0;
      uploadHandler?.onUploadPartComplete(this, blockIndex, block.md5);
    }
    stopwatch.stop();

    snapshot.validateUnchanged();
    final complete = await uploader.merge(
      remotePath: remotePath,
      localPath: snapshot.path,
      snapshot: snapshot,
      uploadid: uploadId,
      blockMd5List: snapshot.md5.blockMd5List,
      rtype: mergeRtype,
    );
    log('上传完成：$complete');
  }
}

/// 上传的回调， 是一个 mixin
///
/// 按需自行覆盖对应的方法
///
/// [onUploadStart] :开始上传
///
/// [onUploadPartComplete] :上传一个块完毕后的回调
///
/// [onUploadComplete] :上传完成时的回调
///
/// [onUploadError] :上传出错时的回调
mixin UploadHelperListener {
  /// 上传开始
  void onUploadStart(BaiduUploadHelper helper) {}

  /// 计算完 md5 后的回调
  void onLocalMd5Complete(BaiduUploadHelper helper) {}

  /// 一个块上传完成的回调
  ///
  /// [index] 为块索引， [md5] 为块的md5
  void onUploadPartComplete(
    BaiduUploadHelper helper,
    int index,
    String md5,
  ) {}

  /// 上传完成的回调
  void onUploadComplete(
    BaiduUploadHelper helper,
  ) {}

  /// 上传出错的回调
  void onUploadError(
    BaiduUploadHelper helper,
    Object error,
    StackTrace stackTrace,
  ) {}
}
