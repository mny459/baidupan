import '../error/upload_validation_error.dart';

// {"path":"\/apps\/dart\u4e0a\u4f20\/1.dart","uploadid":"N1-MjIxLjIxOS4xODQuODA6MTY0NjE5NDAzMzoyNTAzNjA1OTg3MDUxNTYwNTE=","return_type":1,"block_list":[0],"errno":0,"request_id":250360598705156051}
class PreCreate {
  final String? path;
  final int returnType;

  /// 需要上传的分片索引；已规范化普通上传的空列表为第 0 片。
  final List<int> blockList;
  final int errno;
  final int requestId;
  final String? uploadId;

  // 秒传
  bool get fastUpload => returnType == 2;

  const PreCreate({
    required this.path,
    required this.returnType,
    required this.blockList,
    required this.errno,
    required this.requestId,
    required this.uploadId,
  });

  static PreCreate fromJson(Map json) {
    final returnType = json['return_type'];
    final uploadId = json['uploadid'];
    if (returnType is! int || (uploadId != null && uploadId is! String)) {
      throw const BaiduUploadValidationException('百度网盘预上传响应格式无效');
    }
    final blockJson = json['block_list'];
    if ((blockJson == null && returnType != 2) ||
        (blockJson != null &&
            (blockJson is! List || blockJson.any((value) => value is! int)))) {
      throw const BaiduUploadValidationException('百度网盘待上传分片索引必须为整数数组');
    }
    final rawBlocks =
        blockJson == null ? <int>[] : (blockJson as List).cast<int>();
    // 文档明确：普通上传返回空列表时等价于 [0]，不能直接跳过分片。
    final blockList = returnType == 1 &&
            uploadId is String &&
            uploadId.isNotEmpty &&
            rawBlocks.isEmpty
        ? <int>[0]
        : rawBlocks;

    return PreCreate(
      path: json['path'],
      returnType: returnType,
      blockList: List<int>.unmodifiable(blockList),
      errno: json['errno'],
      requestId: json['request_id'],
      uploadId: uploadId as String?,
    );
  }
}

// {"md5":"1fdb978218079ba2c728a995a66e4e46","request_id":1405365793443231054}
class UploadPart {
  final String md5;
  final int requestId;
  final int blockSize;

  UploadPart({
    required this.md5,
    required this.requestId,
    required this.blockSize,
  });

  factory UploadPart.fromJson(Map json, int fileSize) {
    return UploadPart(
      md5: json['md5'],
      requestId: json['request_id'],
      blockSize: fileSize,
    );
  }
}

// {"category":4,"ctime":1646214940,"from_type":1,"fs_id":739070475455326,"isdir":0,"md5":"aba19e3afi901c068bfbc22abd903dea","mtime":1646214940,"path":"\/Test\/Hello\/test_20220302_175540.txt","server_filename":"test_20220302_175540.txt","size":1340,"errno":0,"name":"\/Test\/Hello\/test_20220302_175540.txt"}
class UploadSuccess {
  final int category;
  final int ctime;
  final int fromType;
  final int fsId;
  final int isdir;
  final String md5;
  final int mtime;
  final String path;
  final String? serverFilename;
  final int size;
  final int errno;
  final String name;

  UploadSuccess({
    required this.category,
    required this.ctime,
    required this.fromType,
    required this.fsId,
    required this.isdir,
    required this.md5,
    required this.mtime,
    required this.path,
    required this.serverFilename,
    required this.size,
    required this.errno,
    required this.name,
  });

  factory UploadSuccess.fromJson(Map json) {
    return UploadSuccess(
      category: json['category'],
      ctime: json['ctime'],
      fromType: json['from_type'],
      fsId: json['fs_id'],
      isdir: json['isdir'],
      md5: json['md5'],
      mtime: json['mtime'],
      path: json['path'],
      serverFilename: json['server_filename'],
      size: json['size'],
      errno: json['errno'],
      name: json['name'],
    );
  }
}
