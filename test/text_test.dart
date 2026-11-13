import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumaberth/src/github.dart';
import 'package:lumaberth/src/text.dart';

void main() {
  group('readable', () {
    test('网络异常给出可读提示而不是原始堆栈', () {
      expect(
        readable(TimeoutException('slow', const Duration(seconds: 20))),
        '网络超时，请检查网络后重试',
      );
      expect(
        readable(const SocketException('Connection refused')),
        '网络连接失败，请检查网络后重试',
      );
      expect(
        readable(http.ClientException('Connection closed before full header')),
        '网络连接中断，请稍后重试',
      );
      expect(
        readable(const HandshakeException('certificate verify failed')),
        '安全连接失败，请检查网络或系统时间',
      );
      for (final text in [
        readable(TimeoutException('x', Duration.zero)),
        readable(const SocketException('x')),
        readable(http.ClientException('x')),
      ]) {
        expect(text.contains('Exception'), false);
        expect(hasChinese(text), true);
      }
    });

    test('平台异常优先使用本地化文案，系统文案不直接透出', () {
      expect(
        readable(PlatformException(code: 'codec', message: '原片已移除，请重新选择')),
        '原片已移除，请重新选择',
      );
      expect(
        readable(PlatformException(
          code: 'Unexpected security result code',
          message: 'A required entitlement isn\'t present.',
        )),
        '系统钥匙串拒绝了访问，请重试',
      );
      final generic =
          readable(PlatformException(code: 'unknown', message: 'Some SDK failure 42'));
      expect(generic, '系统拒绝了这次操作，请重试');
      expect(hasChinese(generic), true);
    });

    test('业务异常保留原有中文说明，去掉 Bad state 前缀', () {
      expect(readable(StateError('原片必须小于 2 GiB')), '原片必须小于 2 GiB');
      expect(
        readable(ApiError(403, 'GitHub 拒绝访问，请检查安装范围和读写权限（403）')),
        'GitHub 拒绝访问，请检查安装范围和读写权限（403）',
      );
    });
  });

  group('oauthErrorLabel', () {
    test('把设备授权错误码翻成用户能懂的话', () {
      expect(oauthErrorLabel('access_denied'), contains('取消'));
      expect(oauthErrorLabel('expired_token'), contains('过期'));
      expect(oauthErrorLabel('incorrect_device_code'), contains('不正确'));
      expect(oauthErrorLabel('device_flow_disabled'), contains('Device Flow'));
      expect(oauthErrorLabel('incorrect_client_credentials'), contains('Client ID'));
      expect(oauthErrorLabel('slow_down'), contains('频繁'));
    });

    test('未知错误码和 null 都有兜底文案', () {
      expect(hasChinese(oauthErrorLabel(null)), true);
      expect(hasChinese(oauthErrorLabel('brand_new_code')), true);
      expect(oauthErrorLabel(null).contains('null'), false);
      expect(oauthErrorLabel('brand_new_code').contains('_'), false);
    });
  });
}
