import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// True when [text] contains Han characters: in this project that marks a
/// message written for the user rather than a system diagnostic.
bool hasChinese(String text) => RegExp(r'[\u4e00-\u9fff]').hasMatch(text);

/// Turns an exception into something the user can act on.
///
/// Raw text such as "TimeoutException after 0:00:20.000000: Future not
/// completed" or a bare Security.framework status code says nothing to the
/// person using the app, and slow links make those failures routine.
String readable(Object e) {
  if (e is PlatformException) {
    final message = e.message ?? '';
    // The native layers in this repository write Chinese messages; anything
    // else came from the system and must not be shown verbatim.
    if (hasChinese(message)) return message;
    if (message.contains('entitlement') ||
        message.contains('security result code')) {
      return '系统钥匙串拒绝了访问，请重试';
    }
    return '系统拒绝了这次操作，请重试';
  }
  if (e is TimeoutException) return '网络超时，请检查网络后重试';
  if (e is HandshakeException) return '安全连接失败，请检查网络或系统时间';
  if (e is SocketException) return '网络连接失败，请检查网络后重试';
  if (e is http.ClientException) return '网络连接中断，请稍后重试';
  return e.toString().replaceFirst('Bad state: ', '');
}

/// Plain-language labels for the device flow error codes GitHub returns.
String oauthErrorLabel(Object? code) => switch ('$code') {
  'access_denied' => '你在 GitHub 上取消了授权，请重新连接',
  'expired_token' => '设备码已过期，请重新获取',
  'incorrect_device_code' => '设备码不正确，请重新获取',
  'device_flow_disabled' => '这个 GitHub App 没有启用 Enable Device Flow',
  'incorrect_client_credentials' => 'Client ID 不正确，请从 App 设置页重新复制',
  'unsupported_grant_type' => 'GitHub 不接受这次授权请求，请检查 App 设置',
  'slow_down' => '操作过于频繁，请稍后再试',
  'authorization_pending' => '还在等待你在 GitHub 上确认',
  _ => '设备授权未完成，请重试',
};
