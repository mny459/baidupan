/// 本地上传参数或文件状态不满足百度网盘要求。
///
/// 这类错误需要修复文件或参数后重新上传，不应重试相同请求。
class BaiduUploadValidationException implements Exception {
  const BaiduUploadValidationException(this.message);

  final String message;

  @override
  String toString() => 'BaiduUploadValidationException: $message';
}
