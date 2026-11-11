import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumaberth/src/github.dart';

class StalledUpload extends http.BaseClient {
  final body = StreamController<List<int>>();
  final listening = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    body.onListen = listening.complete;
    return http.StreamedResponse(body.stream, 201);
  }
}

void main() {
  for (final pause in [true, false]) {
    test(
      'stalled upload response ends on ${pause ? "pause" : "timeout"}',
      () async {
        final dir = await Directory.systemTemp.createTemp('upload-');
        final file = await File('${dir.path}/photo').writeAsBytes([1]);
        final client = StalledUpload();
        final stops = StreamController<String>();
        final api = Github(
          client,
          () async => 'test',
          uploadStops: () => stops.stream,
        );
        Timer? deadline;
        void Function()? fireDeadline;
        final upload = runZoned(
          () => api.ensureAsset(
            '/repos/test/photos',
            1,
            [],
            'photo',
            file,
            1,
            '',
          ),
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              if (duration == const Duration(minutes: 10)) {
                deadline = parent.createTimer(
                  zone,
                  const Duration(days: 1),
                  callback,
                );
                fireDeadline = callback;
                return deadline!;
              }
              return parent.createTimer(zone, duration, callback);
            },
          ),
        );
        final expected = expectLater(
          upload,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              contains(pause ? 'paused' : '超时'),
            ),
          ),
        );
        await client.listening.future;
        if (pause) {
          stops.add('paused');
        } else {
          fireDeadline!();
        }
        await expected.timeout(const Duration(seconds: 3));
        expect(client.body.hasListener, false);
        expect(deadline!.isActive, false);
        await stops.close();
        await client.body.close();
        await dir.delete(recursive: true);
      },
    );
  }
}
