import 'dart:convert';

import 'package:baidupan/baidupan.dart';

import 'package:http/http.dart' as http;

/// 处理获取百度的 token
class BaiduAuthManager {
  final String appId;
  final String appSecret;

  BaiduAuthManager(this.appId, this.appSecret);

  String get clientId => appId;

  Uri getAuthUrl({String redirectUri = 'oob'}) {
    return Uri.parse('http://openapi.baidu.com/oauth/2.0/authorize').replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': 'basic,netdisk',
      },
    );
  }

  Future<BaiduAuth> requestAccessToken(String code,
      {String redirectUri = 'oob'}) async {
    final uri = Uri.parse(
      'https://openapi.baidu.com/oauth/2.0/token',
    ).replace(queryParameters: {
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': clientId,
      'client_secret': appSecret,
      'redirect_uri': redirectUri,
    });

    final response = await http.get(uri);
    var body = response.body;
    // print('body: $body');
    final map = json.decode(body);
    if (map['access_token'] == null) {
      throw BaiduPanAuthError(response);
    }
    return BaiduAuth.fromJson(map);
  }

  Future<BaiduAuth> refreshAccessToken(String refreshToken) async {
    final uri = Uri.parse(
      'https://openapi.baidu.com/oauth/2.0/token',
    ).replace(queryParameters: {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      'client_secret': appSecret,
    });

    final response = await http.get(uri);
    var body = response.body;
    // print('body: $body');
    final map = json.decode(body);
    if (map['access_token'] == null) {
      throw BaiduPanAuthError(response);
    }
    return BaiduAuth.fromJson(map);
  }
}
