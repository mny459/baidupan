import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baidupan/baidupan.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _remote = '/apps/一叶 日记/视频+&%#=?.mp4';
const _uploadId = 'private-id+with&equals=';
const _token = 'private-access-token';

http.Response _json(Map<String, Object?> data, http.Request request) =>
    http.Response(jsonEncode(data), 200,
        headers: {'content-type': 'application/json; charset=utf-8'},
        request: request);

Map<String, String> _form(http.Request request) =>
    Uri.splitQueryString(request.body);

Map<String, Object?> _precreate({List<int> blocks = const [0]}) => {
      'errno': 0,
      'request_id': 71,
      'return_type': 1,
      'uploadid': _uploadId,
      'path': _remote,
      'block_list': blocks,
    };

Map<String, Object?> _created(int size, String hash) => {
      'errno': 0,
      'category': 4,
      'ctime': 1,
      'mtime': 1,
      'from_type': 1,
      'fs_id': 2,
      'isdir': 0,
      'md5': hash,
      'path': _remote,
      'server_filename': 'video.mp4',
      'size': size,
      'name': _remote,
    };

class _Listener with UploadHelperListener {
  _Listener({this.onMd5, this.onPart});

  final void Function(BaiduUploadHelper helper)? onMd5;
  final void Function(BaiduUploadHelper helper)? onPart;
  int starts = 0;

  @override
  void onUploadStart(BaiduUploadHelper helper) => starts++;

  @override
  void onLocalMd5Complete(BaiduUploadHelper helper) => onMd5?.call(helper);

  @override
  void onUploadPartComplete(BaiduUploadHelper helper, int index, String md5) =>
      onPart?.call(helper);
}

void main() {
  late Directory fixtureDir;
  late File source;

  setUp(() async {
    fixtureDir = await Directory.systemTemp.createTemp('baidu-test-');
    source = await File('${fixtureDir.path}/本地+&%#=.mp4')
        .writeAsBytes(utf8.encode('original-video-bytes'));
  });

  tearDown(() async {
    if (await fixtureDir.exists()) await fixtureDir.delete(recursive: true);
  });

  group('upload limits', () {
    test('nonempty files and all membership size boundaries', () {
      expect(() => PanUtils.validateUploadSize(0, 0),
          throwsA(isA<BaiduUploadValidationException>()));
      expect(() => PanUtils.validateUploadSize(-1, 0),
          throwsA(isA<BaiduUploadValidationException>()));
      const limits = {
        0: 4 * 1024 * 1024 * 1024,
        1: 10 * 1024 * 1024 * 1024,
        2: 20 * 1024 * 1024 * 1024,
      };
      for (final level in limits.keys) {
        final limit = limits[level]!;
        expect(PanUtils.getMaxFileSize(level), limit);
        expect(PanUtils.validateUploadSize(1, level), 1);
        expect(
            PanUtils.validateUploadSize(limit, level),
            (limit + PanUtils.getBlockSize(level) - 1) ~/
                PanUtils.getBlockSize(level));
        expect(() => PanUtils.validateUploadSize(limit + 1, level),
            throwsA(isA<BaiduUploadValidationException>()));
      }
      expect(PanUtils.maxBlockCount, 1024);
      expect(PanUtils.validateUploadSize(PanUtils.getBlockSize(0) * 1024, 0),
          1024);
    });

    test('block digests must match count, format, and slice limit', () {
      final hash = 'a' * 32;
      expect(
          () => PanUtils.validateBlockMd5List(
              fileSize: 1, memberLevel: 0, blockMd5List: [hash]),
          returnsNormally);
      expect(
          () => PanUtils.validateBlockMd5List(
              fileSize: PanUtils.getBlockSize(0) * 1024,
              memberLevel: 0,
              blockMd5List: List.filled(1024, hash)),
          returnsNormally);
      for (final invalid in [
        <String>[],
        [hash, hash],
        ['A' * 32],
        ['bad-md5'],
        List.filled(1025, hash),
      ]) {
        expect(
            () => PanUtils.validateBlockMd5List(
                fileSize: 1, memberLevel: 0, blockMd5List: invalid),
            throwsA(isA<BaiduUploadValidationException>()));
      }
    });

    test('empty file is rejected without contacting any endpoint', () async {
      await source.writeAsBytes([]);
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return _json(_precreate(), request);
      });
      await http.runWithClient(() async {
        final helper = BaiduUploadHelper(
            accessToken: _token,
            localPath: source.path,
            remotePath: _remote,
            memberLevel: 0);
        await expectLater(helper.startUpload(),
            throwsA(isA<BaiduUploadValidationException>()));
        await expectLater(
            const BaiduPanUploadManager(accessToken: _token).preCreate(
                remotePath: _remote, localPath: source.path, memberLevel: 0),
            throwsA(isA<BaiduUploadValidationException>()));
      }, () => client);
      expect(calls, 0);
    });

    test('oversize sparse file is rejected before hashing, copying, or HTTP',
        () async {
      final file = await source.open(mode: FileMode.write);
      try {
        await file.truncate(PanUtils.getMaxFileSize(0) + 1);
      } finally {
        await file.close();
      }
      var calls = 0;
      await http.runWithClient(() async {
        await expectLater(
            const BaiduPanUploadManager(accessToken: _token).preCreate(
                remotePath: _remote, localPath: source.path, memberLevel: 0),
            throwsA(isA<BaiduUploadValidationException>()));
        await expectLater(
            BaiduUploadHelper(
                    accessToken: _token,
                    localPath: source.path,
                    remotePath: _remote,
                    memberLevel: 0)
                .startUpload(),
            throwsA(isA<BaiduUploadValidationException>()));
      },
          () => MockClient((request) async {
                calls++;
                return _json(_precreate(), request);
              }));
      expect(calls, 0);
    });

    test('empty source emits safe diagnostics even when the logger throws',
        () async {
      await source.writeAsBytes([]);
      final messages = <String>[];
      var calls = 0;
      await http.runWithClient(() async {
        for (final loggerThrows in [false, true]) {
          final helper = BaiduUploadHelper(
              accessToken: _token,
              localPath: source.path,
              remotePath: _remote,
              memberLevel: 0,
              onDiagnostic: (message) {
                messages.add(message);
                if (loggerThrows) throw StateError('simulated logger failure');
              });
          await expectLater(helper.startUpload(),
              throwsA(isA<BaiduUploadValidationException>()));
          expect(helper.isUploading, isFalse);
        }
      },
          () => MockClient((request) async {
                calls++;
                return _json(_precreate(), request);
              }));
      expect(calls, 0);
      expect(messages.length, 2);
      for (final message in messages) {
        for (final secret in [source.path, _remote, _token]) {
          expect(message, isNot(contains(secret)));
        }
        final event = jsonDecode(message) as Map;
        expect(event['stage'], 'precreate');
        expect(event['event'], 'local_validation_error');
        expect(event['size'], 0);
        expect(event['memberLevel'], 0);
        expect(event['errorType'], 'BaiduUploadValidationException');
      }
    });
  });

  group('immutable local snapshot', () {
    test('metadata and digests describe the same isolated bytes', () async {
      final original = await source.readAsBytes();
      final snapshot = await BaiduUploadSnapshot.create(
          localPath: source.path, memberLevel: 0);
      final snapshotPath = snapshot.path;
      try {
        expect(snapshotPath, isNot(source.path));
        expect(snapshot.size, original.length);
        expect(snapshot.memberLevel, 0);
        expect(await snapshot.md5.contentMd5,
            crypto.md5.convert(original).toString());
        expect(snapshot.md5.blockMd5List,
            [crypto.md5.convert(original).toString()]);
        await source.writeAsBytes(utf8.encode('changed'));
        expect(await File(snapshotPath).readAsBytes(), original);
        snapshot.validateUnchanged();
      } finally {
        await snapshot.dispose();
      }
      expect(await File(snapshotPath).exists(), isFalse);
      await snapshot.dispose();
    });

    test('tampering with the copied bytes fails validation', () async {
      final snapshot = await BaiduUploadSnapshot.create(
          localPath: source.path, memberLevel: 0);
      try {
        final copiedFile = File(snapshot.path);
        final modified = await copiedFile.lastModified();
        final original = await copiedFile.readAsBytes();
        original[0] ^= 1;
        await copiedFile.writeAsBytes(original);
        await copiedFile.setLastModified(modified);
        expect(() => snapshot.validateUnchanged(),
            throwsA(isA<BaiduUploadValidationException>()));
      } finally {
        await snapshot.dispose();
      }
    });
  });

  test('upload paths and IDs are encoded exactly once in all three phases',
      () async {
    final snapshot = await BaiduUploadSnapshot.create(
        localPath: source.path, memberLevel: 0);
    final hash = await snapshot.md5.contentMd5;
    final methods = <String>[];
    final client = MockClient((request) async {
      final method = request.url.queryParameters['method']!;
      methods.add(method);
      expect(request.url.queryParameters['access_token'], _token);
      if (method == 'upload') {
        expect(request.url.queryParameters['path'], _remote);
        expect(request.url.queryParameters['uploadid'], _uploadId);
        expect(
            request.bodyBytes, containsAllInOrder(await source.readAsBytes()));
        return _json({'md5': hash, 'request_id': 72}, request);
      }
      final body = _form(request);
      expect(body['path'], _remote);
      expect(body['uploadid'], _uploadId);
      expect(body['block_list'], jsonEncode([hash]));
      expect(body['size'], snapshot.size.toString());
      if (method == 'precreate') {
        expect(body['local_ctime'], matches(r'^\d+$'));
        expect(body['local_mtime'], matches(r'^\d+$'));
        return _json(_precreate(), request);
      }
      return _json(_created(snapshot.size, hash), request);
    });
    try {
      await http.runWithClient(() async {
        final manager = BaiduPanUploadManager(accessToken: _token);
        await manager.preCreate(
            remotePath: _remote,
            localPath: snapshot.path,
            memberLevel: 0,
            uploadid: _uploadId,
            snapshot: snapshot);
        await manager.uploadSinglePart(
            remotePath: _remote,
            localPath: snapshot.path,
            memberLevel: 0,
            uploadid: _uploadId,
            partseq: 0,
            snapshot: snapshot);
        await manager.merge(
            remotePath: _remote,
            localPath: snapshot.path,
            uploadid: _uploadId,
            memberLevel: 0,
            blockMd5List: [hash],
            snapshot: snapshot);
      }, () => client);
      expect(methods, ['precreate', 'upload', 'create']);
    } finally {
      await snapshot.dispose();
    }
  });

  test('shared form encoder preserves folder paths and serialized file lists',
      () async {
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      final manager = BaiduPanFileManager(_token);
      await manager.createFolder(path: _remote);
      await manager.delete([_remote]);
      await manager.rename([RenameItem(path: _remote, newName: '新+&%#=.mp4')]);
    },
        () => MockClient((request) async {
              requests.add(request);
              return _json({'errno': 0}, request);
            }));
    expect(_form(requests[0])['path'], _remote);
    expect(jsonDecode(_form(requests[1])['filelist']!), [_remote]);
    expect(jsonDecode(_form(requests[2])['filelist']!), [
      {'path': _remote, 'newname': '新+&%#=.mp4'}
    ]);
  });

  test('direct precreate invalidates cached digests after a source change',
      () async {
    final cached = BaiduMd5(filePath: source.path, memberLevel: 0);
    await cached.prepareInIsolate();
    final oldHash = await cached.contentMd5;
    final changed = utf8.encode('direct-api-replacement-with-new-size');
    await source.writeAsBytes(changed);
    final newHash = crypto.md5.convert(changed).toString();
    expect(newHash, isNot(oldHash));
    var calls = 0;
    await http.runWithClient(() async {
      await const BaiduPanUploadManager(accessToken: _token).preCreate(
          remotePath: _remote,
          localPath: source.path,
          memberLevel: 0,
          md5: cached);
    },
        () => MockClient((request) async {
              calls++;
              final body = _form(request);
              expect(body['size'], changed.length.toString());
              expect(body['content-md5'], newHash);
              expect(body['slice-md5'], newHash);
              expect(body['block_list'], jsonEncode([newHash]));
              return _json(_precreate(), request);
            }));
    expect(calls, 1);
  });

  test('invalid part indices never send multipart data', () async {
    var calls = 0;
    await http.runWithClient(() async {
      for (final index in [-1, 1]) {
        await expectLater(
            const BaiduPanUploadManager(accessToken: _token).uploadSinglePart(
                remotePath: _remote,
                localPath: source.path,
                memberLevel: 0,
                uploadid: _uploadId,
                partseq: index),
            throwsA(isA<BaiduUploadValidationException>()));
      }
    },
        () => MockClient((request) async {
              calls++;
              return _json({'md5': 'a' * 32, 'request_id': 72}, request);
            }));
    expect(calls, 0);
  });

  for (final failFirst in [false, true]) {
    test('helper keeps one snapshot across ${failFirst ? 'retry' : 'upload'}',
        () async {
      final original = await source.readAsBytes();
      final hash = crypto.md5.convert(original).toString();
      final precreateBodies = <Map<String, String>>[];
      var merges = 0;
      String? copyPath;
      Map<String, dynamic>? savedProgress;
      final helper = BaiduUploadHelper(
          accessToken: _token,
          localPath: source.path,
          remotePath: _remote,
          memberLevel: 0,
          totalRetryCount: 2);
      final client = MockClient((request) async {
        switch (request.url.queryParameters['method']) {
          case 'precreate':
            final body = _form(request);
            precreateBodies.add(body);
            expect(body['rtype'], '3');
            expect(body['size'], original.length.toString());
            expect(body['content-md5'], hash);
            expect(body['block_list'], jsonEncode([hash]));
            await source.writeAsBytes(utf8.encode('source-changed-and-longer'));
            if (failFirst && precreateBodies.length == 1) {
              throw const SocketException(
                  'simulated temporary connection loss');
            }
            return _json(_precreate(), request);
          case 'upload':
            expect(request.bodyBytes, containsAllInOrder(original));
            return _json({'md5': hash, 'request_id': 72}, request);
          case 'create':
            merges++;
            final body = _form(request);
            expect(body['rtype'], '3');
            expect(body['size'], original.length.toString());
            expect(body['block_list'], jsonEncode([hash]));
            return _json(_created(original.length, hash), request);
          default:
            fail('Unexpected network request ${request.url}');
        }
      });
      final listener = _Listener(onMd5: (value) {
        copyPath ??= value.md5.filePath;
        expect(value.md5.filePath, copyPath);
      }, onPart: (value) {
        savedProgress = value.getSaveProgressMap();
      });
      await http.runWithClient(
          () => helper.startUpload(listener), () => client);
      expect(precreateBodies.length, failFirst ? 2 : 1);
      expect(listener.starts, 1);
      expect(merges, 1);
      expect(copyPath, isNotNull);
      expect(copyPath, isNot(source.path));
      expect(File(copyPath!).existsSync(), isFalse);
      expect(savedProgress!['localPath'], source.absolute.path);
      expect(savedProgress!['saveFileLength'], original.length);
      expect((savedProgress!['md5'] as Map)['filePath'], source.absolute.path);
      expect(jsonEncode(savedProgress), isNot(contains(copyPath!)));
    });
  }

  test(
      'a fresh top-level run recalculates changed bytes and drops prior uploadid',
      () async {
    final hashes = <String>[];
    final copiedPaths = <String>[];
    final helper = BaiduUploadHelper(
        accessToken: _token,
        localPath: source.path,
        remotePath: _remote,
        memberLevel: 0);
    final listener = _Listener(onMd5: (value) {
      copiedPaths.add(value.md5.filePath);
    });
    await http.runWithClient(() async {
      await helper.startUpload(listener);
      await source.writeAsBytes(utf8.encode('second-video-content'));
      await helper.startUpload(listener);
    },
        () => MockClient((request) async {
              final body = _form(request);
              expect(body.containsKey('uploadid'), isFalse);
              hashes.add(body['content-md5']!);
              return _json({
                'errno': 0,
                'request_id': 73,
                'return_type': 2,
                'block_list': <int>[],
              }, request);
            }));
    expect(hashes.length, 2);
    expect(hashes[0], isNot(hashes[1]));
    expect(listener.starts, 2);
    expect(copiedPaths[0], isNot(copiedPaths[1]));
    expect(copiedPaths.every((path) => !File(path).existsSync()), isTrue);
  });

  test('resume rechecks digests even when source size and mtime are unchanged',
      () async {
    await source.setLastModified(DateTime.utc(2026, 1, 1));
    final digest = BaiduMd5(filePath: source.path, memberLevel: 0);
    await digest.prepareInIsolate();
    final originalStat = await source.stat();
    final saved = {
      'localPath': source.absolute.path,
      'remotePath': _remote,
      'memberLevel': 0,
      'saveFileLength': originalStat.size,
      'lastModified': originalStat.modified.millisecondsSinceEpoch,
      'md5': digest.toMap(),
      'uploadId': _uploadId,
      'uploadCount': 0,
      'preCreateRtype': UploadRenameRtype.overwrite.index,
      'mergeRtype': UploadRenameRtype.overwrite.index,
    };
    final changed = await source.readAsBytes();
    changed[0] ^= 1;
    await source.writeAsBytes(changed);
    await source.setLastModified(originalStat.modified);
    var calls = 0;
    await http.runWithClient(() async {
      final resumed = BaiduUploadHelper.resumeFromMap(
          accessToken: _token, resumeMap: saved);
      await expectLater(resumed.startUpload(),
          throwsA(isA<BaiduUploadValidationException>()));
      expect(resumed.getSaveProgressMap()['uploadId'], isNull);
    },
        () => MockClient((request) async {
              calls++;
              return _json(_precreate(), request);
            }));
    expect(calls, 0);
  });

  test('errno 2 is terminal and disposes the snapshot', () async {
    var calls = 0;
    String? copyPath;
    final helper = BaiduUploadHelper(
        accessToken: _token,
        localPath: source.path,
        remotePath: _remote,
        memberLevel: 0,
        totalRetryCount: 5);
    await http.runWithClient(() async {
      await expectLater(helper.startUpload(_Listener(onMd5: (value) {
        copyPath = value.md5.filePath;
      })), throwsA(isA<BaiduPanError>().having((e) => e.errno, 'errno', 2)));
    },
        () => MockClient((request) async {
              calls++;
              return _json({'errno': 2, 'request_id': 99}, request);
            }));
    expect(calls, 1);
    expect(helper.isUploading, isFalse);
    expect(copyPath, isNotNull);
    expect(File(copyPath!).existsSync(), isFalse);
  });

  group('precreate response protocol', () {
    test('mixed integer and string indices abort before part upload', () async {
      var calls = 0;
      final helper = BaiduUploadHelper(
          accessToken: _token,
          localPath: source.path,
          remotePath: _remote,
          memberLevel: 0,
          totalRetryCount: 3);
      await http.runWithClient(() async {
        await expectLater(helper.startUpload(),
            throwsA(isA<BaiduUploadValidationException>()));
      },
          () => MockClient((request) async {
                calls++;
                return _json({
                  ..._precreate(),
                  'block_list': [0, '1'],
                }, request);
              }));
      expect(calls, 1);
    });

    test('normal upload with empty indices still uploads its first block',
        () async {
      final methods = <String>[];
      final hash = crypto.md5.convert(await source.readAsBytes()).toString();
      final helper = BaiduUploadHelper(
          accessToken: _token,
          localPath: source.path,
          remotePath: _remote,
          memberLevel: 0);
      await http.runWithClient(
          () => helper.startUpload(),
          () => MockClient((request) async {
                final method = request.url.queryParameters['method']!;
                methods.add(method);
                if (method == 'precreate') {
                  return _json(_precreate(blocks: []), request);
                }
                if (method == 'upload') {
                  expect(request.url.queryParameters['partseq'], '0');
                  return _json({'md5': hash, 'request_id': 72}, request);
                }
                return _json(_created(source.lengthSync(), hash), request);
              }));
      expect(methods, ['precreate', 'upload', 'create']);
      expect(helper.getProgress(), 1);
    });

    test('return type 2 completes fast upload even with an upload ID',
        () async {
      final methods = <String>[];
      final helper = BaiduUploadHelper(
          accessToken: _token,
          localPath: source.path,
          remotePath: _remote,
          memberLevel: 0);
      await http.runWithClient(
          () => helper.startUpload(),
          () => MockClient((request) async {
                methods.add(request.url.queryParameters['method']!);
                return _json({
                  ..._precreate(blocks: []),
                  'return_type': 2,
                }, request);
              }));
      expect(methods, ['precreate']);
      expect(helper.getProgress(), 1);
    });
  });

  test('part API errno stays BaiduPanError and never reaches merge', () async {
    final methods = <String>[];
    final helper = BaiduUploadHelper(
        accessToken: _token,
        localPath: source.path,
        remotePath: _remote,
        memberLevel: 0,
        totalRetryCount: 1);
    await http.runWithClient(() async {
      await expectLater(helper.startUpload(),
          throwsA(isA<BaiduPanError>().having((e) => e.errno, 'errno', 2)));
    },
        () => MockClient((request) async {
              final method = request.url.queryParameters['method']!;
              methods.add(method);
              return _json(
                  method == 'precreate'
                      ? _precreate()
                      : {'errno': 2, 'request_id': 98},
                  request);
            }));
    expect(methods, ['precreate', 'upload']);
  });

  test('returned block digest mismatch aborts before merge', () async {
    final methods = <String>[];
    final helper = BaiduUploadHelper(
        accessToken: _token,
        localPath: source.path,
        remotePath: _remote,
        memberLevel: 0,
        totalRetryCount: 1);
    await http.runWithClient(() async {
      await expectLater(
          helper.startUpload(), throwsA(isA<BaiduUploadValidationException>()));
    },
        () => MockClient((request) async {
              final method = request.url.queryParameters['method']!;
              methods.add(method);
              return _json(
                  method == 'precreate'
                      ? _precreate()
                      : {'md5': '0' * 32, 'request_id': 97},
                  request);
            }));
    expect(methods, ['precreate', 'upload']);
  });

  test('precreate diagnostics are useful without exposing credentials or files',
      () async {
    final logs = <String>[];
    var responses = 0;
    final originalHash =
        crypto.md5.convert(await source.readAsBytes()).toString();
    await runZoned(() async {
      await http.runWithClient(() async {
        final manager = BaiduPanUploadManager(
            accessToken: _token, showLog: true, onDiagnostic: logs.add);
        await expectLater(
            manager.preCreate(
                remotePath: _remote,
                localPath: source.path,
                memberLevel: 0,
                uploadid: _uploadId,
                rtype: UploadRenameRtype.overwrite),
            throwsA(isA<BaiduPanError>()));
        await manager.preCreate(
            remotePath: _remote,
            localPath: source.path,
            memberLevel: 0,
            uploadid: _uploadId);
      },
          () => MockClient((request) async {
                responses++;
                if (responses == 2) {
                  return _json({
                    ..._precreate(),
                    'access_token': _token,
                    'content-md5': originalHash,
                  }, request);
                }
                return _json({
                  'errno': 2,
                  'request_id': 123456789,
                  'path': _remote,
                  'uploadid': _uploadId,
                  'access_token': _token,
                  'errmsg': 'bad parameter $_remote $_uploadId $originalHash',
                }, request);
              }));
    }, zoneSpecification: ZoneSpecification(print: (_, __, ___, line) {
      logs.add(line);
    }));
    final combined = logs.join('\n');
    for (final secret in [
      _token,
      _remote,
      Uri.encodeComponent(_remote),
      source.path,
      _uploadId,
      originalHash,
    ]) {
      expect(combined, isNot(contains(secret)));
    }
    final events = logs.map((line) => jsonDecode(line) as Map).toList();
    expect(events.any((event) => event['size'] == source.lengthSync()), isTrue);
    expect(events.any((event) => event['blockCount'] == 1), isTrue);
    expect(
        events.any((event) => event['blockSize'] == PanUtils.getBlockSize(0)),
        isTrue);
    expect(events.any((event) => event['memberLevel'] == 0), isTrue);
    expect(events.any((event) => event['rtype'] == 3), isTrue);
    expect(events.any((event) => event['attempt'] == 1), isTrue);
    expect(events.any((event) => event['errno'] == 2), isTrue);
    expect(events.any((event) => event['event'] == 'response'), isTrue);
    expect(events.any((event) => event['request_id'] == 123456789), isTrue);
  });

  for (final networkFailure in [true, false]) {
    test(
        'helper debug logs redact ${networkFailure ? 'HTTP exceptions' : 'server echoes'}',
        () async {
      final messages = <String>[];
      final hash = crypto.md5.convert(await source.readAsBytes()).toString();
      final uri = Uri.https('example.invalid', '/upload', {
        'access_token': _token,
        'path': _remote,
        'uploadid': _uploadId,
      });
      final helper = BaiduUploadHelper(
          accessToken: _token,
          localPath: source.path,
          remotePath: _remote,
          memberLevel: 0,
          totalRetryCount: 1,
          onDiagnostic: messages.add)
        ..isShowLog = true;
      await runZoned(() async {
        await http.runWithClient(() async {
          await expectLater(
              helper.startUpload(),
              throwsA(networkFailure
                  ? isA<http.ClientException>()
                  : isA<BaiduPanError>()));
        },
            () => MockClient((request) async {
                  if (networkFailure) {
                    throw http.ClientException(
                        'failure $uri ${source.path} $_remote $_uploadId $hash',
                        uri);
                  }
                  return _json({
                    'errno': 2,
                    'request_id': 123,
                    'access_token': _token,
                    'path': _remote,
                    'uploadid': _uploadId,
                    'md5': hash,
                    'errmsg':
                        'failure $uri ${source.path} $_remote $_uploadId $hash',
                  }, request);
                }));
      }, zoneSpecification: ZoneSpecification(print: (_, __, ___, line) {
        messages.add(line);
      }));
      final combined = messages.join('\n');
      for (final secret in [
        _token,
        _remote,
        Uri.encodeComponent(_remote),
        source.path,
        _uploadId,
        hash,
        uri.toString(),
      ]) {
        expect(combined, isNot(contains(secret)));
      }
      final events = messages.map((line) => jsonDecode(line) as Map).toList();
      expect(events.any((event) => event['event'] == 'upload_error'), isTrue);
      expect(events.any((event) => event['event'] == 'error'), isTrue);
    });
  }

  test('diagnostics omit nonnumeric protocol metadata instead of echoing it',
      () async {
    final messages = <String>[];
    final marker = 'malicious $_token $_remote $_uploadId ${source.path}';
    final responses = [
      {'errno': 2, 'request_id': marker},
      {'errno': marker, 'request_id': 124},
      {..._precreate(), 'request_id': marker},
      {..._precreate(), 'return_type': marker},
    ];
    var calls = 0;
    await http.runWithClient(() async {
      for (var index = 0; index < responses.length; index++) {
        await expectLater(
            BaiduPanUploadManager(
                    accessToken: _token, onDiagnostic: messages.add)
                .preCreate(
                    remotePath: _remote,
                    localPath: source.path,
                    memberLevel: 0),
            throwsA(anything));
      }
    },
        () => MockClient((request) async {
              return _json(responses[calls++], request);
            }));
    expect(calls, responses.length);
    final combined = messages.join('\n');
    for (final secret in [marker, _token, _remote, _uploadId, source.path]) {
      expect(combined, isNot(contains(secret)));
    }
    for (final message in messages) {
      final event = jsonDecode(message) as Map;
      for (final field in [
        'errno',
        'request_id',
        'return_type',
        'httpStatus'
      ]) {
        if (event.containsKey(field)) expect(event[field], isA<num>());
      }
    }
  });
}
