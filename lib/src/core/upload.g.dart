part of 'pan.dart';

typedef Md5Calculated = void Function(BaiduMd5 md5);

/// 百度网盘三阶段上传。手动调用时应为三个阶段传入同一个文件快照。
class BaiduPanUploadManager with BaiduPanMixin {
  const BaiduPanUploadManager({
    required this.accessToken,
    this.showLog = false,
    this.secretAccessToken = true,
    this.onDiagnostic,
  });

  @override
  final String accessToken;
  @override
  final bool showLog;
  @override
  final bool secretAccessToken;

  /// 只输出字段摘要；不会包含令牌、原始路径、上传 ID 或文件 MD5。
  final void Function(String message)? onDiagnostic;

  String _fingerprint(String value) =>
      crypto.sha256.convert(utf8.encode(value)).toString().substring(0, 12);

  void _diagnostic(Map<String, Object?> context) {
    // 服务端诊断字段也只接受数值，避免异常响应回显敏感参数。
    for (final key in ['errno', 'request_id', 'return_type', 'httpStatus']) {
      final value = context[key];
      final numericRequestId = key == 'request_id' &&
          value is String &&
          RegExp(r'^\d+$').hasMatch(value);
      if (value is! int && !numericRequestId) context.remove(key);
    }
    final message = json.encode(context);
    if (onDiagnostic != null) {
      // 日志写入失败不能改变上传结果或触发上传重试。
      try {
        onDiagnostic!(message);
      } catch (_) {
        if (showLog) print(message);
      }
    } else if (showLog) {
      print(message);
    }
  }

  void _validatePath(String remotePath) {
    if (!remotePath.startsWith('/') || remotePath.contains('\u0000')) {
      throw BaiduUploadValidationException('百度网盘上传路径必须为有效的绝对路径');
    }
  }

  bool _sameStat(FileStat before, FileStat after) =>
      before.type == after.type &&
      before.size == after.size &&
      before.modified == after.modified &&
      before.changed == after.changed;

  void _validateSnapshot(
      BaiduUploadSnapshot snapshot, String localPath, int memberLevel) {
    if (File(snapshot.path).absolute.path != File(localPath).absolute.path ||
        snapshot.memberLevel != memberLevel) {
      throw BaiduUploadValidationException('上传快照与当前文件或会员等级不一致');
    }
    snapshot.validateUnchanged();
  }

  /// 预上传；参数中的大小与指纹必须来自同一份文件。
  Future<PreCreate> preCreate({
    required String remotePath,
    required String localPath,
    UploadRenameRtype rtype = UploadRenameRtype.none,
    required int memberLevel,
    String? uploadid,
    BaiduMd5? md5,
    Md5Calculated? onMd5Calculated,
    BaiduUploadSnapshot? snapshot,
    int attempt = 1,
  }) async {
    final context = <String, Object?>{
      'stage': 'precreate',
      'attempt': attempt,
      'pathFingerprint': _fingerprint(remotePath),
      'memberLevel': memberLevel,
      'blockSize': PanUtils.getBlockSize(memberLevel),
      'rtype': rtype.index,
      'hasUploadId': uploadid != null,
      if (uploadid != null) 'uploadIdFingerprint': _fingerprint(uploadid),
    };
    try {
      _validatePath(remotePath);
      if (uploadid != null && uploadid.isEmpty) {
        throw BaiduUploadValidationException('预上传任务 ID 不能为空');
      }
      final file = File(localPath);
      final before = file.statSync();
      if (before.type != FileSystemEntityType.file) {
        throw BaiduUploadValidationException('百度网盘上传源必须为已存在的普通文件');
      }
      if (snapshot != null) {
        _validateSnapshot(snapshot, localPath, memberLevel);
      }
      final size = snapshot?.size ?? before.size;
      context['size'] = size;
      context['blockCount'] = PanUtils.validateUploadSize(size, memberLevel);
      final baiduMd5 = snapshot?.md5 ??
          md5 ??
          BaiduMd5(filePath: localPath, memberLevel: memberLevel);
      if (File(baiduMd5.filePath).absolute.path != file.absolute.path ||
          baiduMd5.memberLevel != memberLevel) {
        throw BaiduUploadValidationException('文件 MD5 与上传文件或分片规则不一致');
      }
      await baiduMd5.prepareInIsolate();
      final blockMd5 = baiduMd5.blockMd5List;
      PanUtils.validateBlockMd5List(
        fileSize: size,
        memberLevel: memberLevel,
        blockMd5List: blockMd5,
      );
      final contentMd5 = await baiduMd5.contentMd5;
      final sliceMd5 = baiduMd5.sliceMd5;
      final md5Pattern = RegExp(r'^[0-9a-f]{32}$');
      if (!md5Pattern.hasMatch(contentMd5) || !md5Pattern.hasMatch(sliceMd5)) {
        throw BaiduUploadValidationException('文件校验值必须为 32 位小写 MD5');
      }
      onMd5Calculated?.call(baiduMd5);
      if (!_sameStat(before, file.statSync())) {
        throw BaiduUploadValidationException('计算上传参数时文件发生变化，请重新上传');
      }
      snapshot?.validateUnchanged();
      context['blockListFingerprint'] = _fingerprint(json.encode(blockMd5));
      final seconds =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
      final body = <String, String>{
        'path': remotePath,
        'size': size.toString(),
        'isdir': '0',
        'autoinit': '1',
        'rtype': rtype.index.toString(),
        'block_list': json.encode(blockMd5),
        'content-md5': contentMd5,
        'slice-md5': sliceMd5,
        'local_ctime': seconds,
        'local_mtime': seconds,
        if (uploadid != null) 'uploadid': uploadid,
      };
      _diagnostic({...context, 'event': 'request'});
      final map = await _post(
        method: 'precreate',
        bodyParams: body,
        suppressLog: true,
      );
      final preCreate = PreCreate.fromJson(map);
      _diagnostic({
        ...context,
        'event': 'response',
        'errno': map['errno'],
        'request_id': map['request_id'],
        'return_type': preCreate.returnType,
        'requestedBlockCount': preCreate.blockList.length,
      });
      return preCreate;
    } catch (error) {
      _diagnostic({
        ...context,
        'event': 'error',
        'errorType': error.runtimeType.toString(),
        if (error is BaiduPanError) ...{
          'errno': error.responseMap['errno'],
          'request_id': error.responseMap['request_id'],
          'httpStatus': error.response.statusCode,
        },
        if (error is BaiduUploadValidationException)
          'validationMessage': error.message,
      });
      rethrow;
    }
  }

  Future<UploadPart> uploadSinglePart({
    required String remotePath,
    required String localPath,
    required int memberLevel,
    required String uploadid,
    required int partseq,
    BaiduUploadSnapshot? snapshot,
  }) async {
    _validatePath(remotePath);
    if (uploadid.isEmpty) {
      throw BaiduUploadValidationException('分片上传任务 ID 不能为空');
    }
    if (snapshot != null) {
      _validateSnapshot(snapshot, localPath, memberLevel);
    }
    final file = File(localPath);
    final before = file.statSync();
    final blockCount = PanUtils.validateUploadSize(before.size, memberLevel);
    if (partseq < 0 || partseq >= blockCount) {
      throw BaiduUploadValidationException('上传分片序号超出文件范围');
    }
    final blockSize = PanUtils.getBlockSize(memberLevel);
    final start = blockSize * partseq;
    final available = before.size - start;
    final length = available < blockSize ? available : blockSize;
    final uploadBytes = Uint8List(length);
    final accessFile = file.openSync();
    try {
      accessFile.setPositionSync(start);
      var read = 0;
      while (read < length) {
        final count = accessFile.readIntoSync(uploadBytes, read, length);
        if (count == 0) {
          throw BaiduUploadValidationException('上传文件读取不完整，请重新上传');
        }
        read += count;
      }
    } finally {
      accessFile.closeSync();
    }
    if (!_sameStat(before, file.statSync())) {
      throw BaiduUploadValidationException('读取上传分片时文件发生变化');
    }
    snapshot?.validateUnchanged();
    final uri = Uri(
      scheme: 'https',
      host: 'd.pcs.baidu.com',
      path: '/rest/2.0/pcs/superfile2',
      queryParameters: {
        'access_token': accessToken,
        'method': 'upload',
        'type': 'tmpfile',
        'path': remotePath,
        'uploadid': uploadid,
        'partseq': partseq.toString(),
      },
    );
    final request = http.MultipartRequest('POST', uri);
    request.files.add(http.MultipartFile.fromBytes(
      'file',
      uploadBytes,
      filename: Uri.file(remotePath).pathSegments.last,
    ));
    final streamed = await request.send().timeout(_uploadPartTimeout);
    final response =
        await http.Response.fromStream(streamed).timeout(_uploadPartTimeout);
    final map = json.decode(utf8.decode(response.bodyBytes));
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        (map['errno'] != null && map['errno'] != 0)) {
      throw BaiduPanError(response);
    }
    if (map['md5'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(map['md5'] as String)) {
      throw BaiduUploadValidationException('分片上传响应缺少有效的 MD5');
    }
    return UploadPart.fromJson(map, uploadBytes.length);
  }

  /// 合并创建。传入 snapshot 时同时验证固定大小和完整分片清单。
  Future<UploadSuccess> merge({
    required String remotePath,
    required String localPath,
    required String uploadid,
    required List<String> blockMd5List,
    UploadRenameRtype rtype = UploadRenameRtype.alwaysRename,
    BaiduUploadSnapshot? snapshot,
    int? memberLevel,
  }) async {
    _validatePath(remotePath);
    if (uploadid.isEmpty) {
      throw BaiduUploadValidationException('创建文件的上传任务 ID 不能为空');
    }
    final file = File(localPath);
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw BaiduUploadValidationException('百度网盘不支持上传空文件或非普通文件');
    }
    final size = snapshot?.size ?? stat.size;
    final level = snapshot?.memberLevel ?? memberLevel;
    if (snapshot != null) {
      _validateSnapshot(snapshot, localPath, snapshot.memberLevel);
      if (memberLevel != null && memberLevel != snapshot.memberLevel) {
        throw BaiduUploadValidationException('合并文件的分片规则与快照不一致');
      }
      if (json.encode(blockMd5List) != json.encode(snapshot.md5.blockMd5List)) {
        throw BaiduUploadValidationException('合并文件的分片清单与上传快照不一致');
      }
    }
    if (level != null) {
      PanUtils.validateBlockMd5List(
        fileSize: size,
        memberLevel: level,
        blockMd5List: blockMd5List,
      );
    } else if (size > PanUtils.getMaxFileSize(2) ||
        blockMd5List.isEmpty ||
        blockMd5List.length > PanUtils.maxBlockCount ||
        blockMd5List
            .any((value) => !RegExp(r'^[0-9a-f]{32}$').hasMatch(value))) {
      // 保留旧的手动调用兼容性；其会员等级未知时不假设分片大小。
      throw BaiduUploadValidationException('合并文件大小或分片清单无效');
    }
    final map = await _post(
      method: 'create',
      bodyParams: {
        'path': remotePath,
        'size': size.toString(),
        'isdir': '0',
        'uploadid': uploadid,
        'rtype': rtype.index.toString(),
        'block_list': json.encode(blockMd5List),
      },
      suppressLog: true,
    );
    return UploadSuccess.fromJson(map);
  }
}

/// 上传文件的命名策略
///
/// 文件命名策略，默认0
/// 0 为不重命名，返回冲突
/// 1 为只要path冲突即重命名
/// 2 为path冲突且block_list不同才重命名
/// 3 为覆盖
enum UploadRenameRtype {
  /// 不重命名
  none,

  /// 只要 path 冲突即重命名
  alwaysRename,

  /// path 冲突且 block_list 不同才重命名
  renameOnBlockList,

  /// 覆盖
  overwrite,
}

typedef BaiduUploadProgress = Function(int count, int max);
