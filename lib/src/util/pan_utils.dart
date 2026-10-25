import '../error/upload_validation_error.dart';

/// 一些百度网盘的方法
class PanUtils {
  static const int maxBlockCount = 1024;
  static const int _gib = 1024 * 1024 * 1024;

  static int getBlockSize(int memberLevel) {
    switch (memberLevel) {
      case 1:
        return 16 * 1024 * 1024;
      case 2:
        return 32 * 1024 * 1024;
      default:
        return 4 * 1024 * 1024;
    }
  }

  static int getMaxFileSize(int memberLevel) {
    switch (memberLevel) {
      case 1:
        return 10 * _gib;
      case 2:
        return 20 * _gib;
      default:
        return 4 * _gib;
    }
  }

  /// 校验文件大小，并返回按当前会员等级切片后的数量。
  static int validateUploadSize(int size, int memberLevel) {
    if (size <= 0) {
      throw const BaiduUploadValidationException('文件为空，不能上传到百度网盘');
    }
    final maxSize = getMaxFileSize(memberLevel);
    if (size > maxSize) {
      throw BaiduUploadValidationException(
        '文件大小超过当前百度网盘账号的单文件上限（${maxSize ~/ _gib} GiB）',
      );
    }
    final blockSize = getBlockSize(memberLevel);
    final blockCount = (size + blockSize - 1) ~/ blockSize;
    if (blockCount > maxBlockCount) {
      throw const BaiduUploadValidationException('文件分片数超过百度网盘的 1024 片上限');
    }
    return blockCount;
  }

  static void validateBlockMd5List({
    required int fileSize,
    required int memberLevel,
    required List<String> blockMd5List,
  }) {
    final expectedCount = validateUploadSize(fileSize, memberLevel);
    if (blockMd5List.length > maxBlockCount) {
      throw const BaiduUploadValidationException('文件分片数超过百度网盘的 1024 片上限');
    }
    if (blockMd5List.length != expectedCount) {
      throw const BaiduUploadValidationException('文件大小与分片数量不一致，请重新生成上传任务');
    }
    final md5Pattern = RegExp(r'^[0-9a-f]{32}$');
    if (blockMd5List.any((value) => !md5Pattern.hasMatch(value))) {
      throw const BaiduUploadValidationException('文件分片 MD5 必须是 32 位小写十六进制字符串');
    }
  }
}
