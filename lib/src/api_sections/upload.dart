import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart';
import 'package:http_parser/http_parser.dart';
import 'package:meta/meta.dart';
import 'package:mime_type/mime_type.dart';
import 'package:uploadcare_client/src/cancel_token.dart';
import 'package:uploadcare_client/src/cancel_upload_exception.dart';
import 'package:uploadcare_client/src/concurrent_runner.dart';
import 'package:uploadcare_client/src/entities/entities.dart';
import 'package:uploadcare_client/src/file/file.dart';
import 'package:uploadcare_client/src/isolate_worker.dart';
import 'package:uploadcare_client/src/mixins/mixins.dart';
import 'package:uploadcare_client/src/options.dart';
import 'package:uploadcare_client/src/transport.dart';

const int _kChunkSize = 5242880;
const int _kRecomendedMaxFilesizeForBaseUpload = 10000000;

typedef void ProgressListener(ProgressEntity progress);

/// Provides API for uploading files
///
/// ```dart
/// final upload = ApiUpload(options: options);
/// ...
/// final file1 = SharedFile(File('/some/file'));
/// final file2 = 'https://some/file';
///
/// final id1 = await upload.auto(file1); // File instance
/// final id2 = await upload.auto(file2); // URL to file
/// final id3 = await upload.auto(file1.path) // path to file;
/// ```
///
/// Run upload process in isolate
/// ```dart
/// final upload = ApiUpload(options: options);
/// ...
/// final id = await upload.auto(SharedFile(File('/some/file')), runInIsolate: true);
/// ```
class ApiUpload with OptionsShortcutMixin, TransportHelperMixin {
  final ClientOptions options;

  ApiUpload({
    @required this.options,
  }) : assert(options != null);

  /// Upload file [resource] according to type
  /// if `String` makes [fromUrl] upload if it is http/https url or try retrieve [SharedFile] if path is absolute, otherwise make an `SharedFile` request according to size
  Future<String> auto(
    Object resource, {
    bool storeMode,
    ProgressListener onProgress,
    CancelToken cancelToken,
    bool runInIsolate = false,
  }) async {
    assert(resource is String || resource is SharedFile,
        'The resource should be one of File or URL and File path');
    assert(runInIsolate != null);

    if (runInIsolate)
      return _runInIsolate(
        resource,
        storeMode: storeMode,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );

    if (resource is String && resource.isNotEmpty) {
      Uri uri = Uri.tryParse(resource);

      if (uri != null) {
        if (['http', 'https'].contains(uri.scheme)) {
          return fromUrl(
            resource,
            storeMode: storeMode,
            onProgress: onProgress,
          );
        } else if (uri.hasAbsolutePath) {
          resource = SharedFile.fromUri(uri);
        } else {
          throw Exception('Cannot parse URL from string');
        }
      }
    }

    if (resource is SharedFile) {
      final file = resource;
      final filesize = await file.length();

      if (filesize > _kRecomendedMaxFilesizeForBaseUpload)
        return multipart(
          file,
          storeMode: storeMode,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );

      return base(
        file,
        storeMode: storeMode,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }

    throw Exception('Make sure you passed File or URL string');
  }

  /// Make upload to `/base` endpoint
  ///
  /// [storeMode]`=null` - auto store
  /// [storeMode]`=true` - store file
  /// [storeMode]`=false` - keep file for 24h in storage
  /// [onProgress] subscribe to progress event
  /// [cancelToken] make cancelable request
  Future<String> base(
    SharedFile file, {
    bool storeMode,
    ProgressListener onProgress,
    CancelToken cancelToken,
  }) async {
    assert(file != null, 'The file cannot be null');
    final filename = file.name;
    final filesize = await file.length();

    ProgressEntity progress = ProgressEntity(0, filesize);

    final client =
        createMultipartRequest('POST', buildUri('$uploadUrl/base/'), false)
          ..fields.addAll({
            'UPLOADCARE_PUB_KEY': publicKey,
            'UPLOADCARE_STORE': resolveStoreModeParam(storeMode),
            if (options.useSignedUploads) ..._signUpload(),
          })
          ..files.add(
            MultipartFile(
              'file',
              file.openRead().transform(
                    StreamTransformer.fromHandlers(
                      handleData: (data, sink) {
                        final next = progress.copyWith(
                            uploaded: progress.uploaded + data.length);
                        final shouldCall = next.value > progress.value;
                        progress = next;

                        if (onProgress != null && shouldCall)
                          onProgress(progress);
                        sink.add(data);
                      },
                      handleDone: (sink) => sink.close(),
                    ),
                  ),
              filesize,
              filename: filename,
              contentType: MediaType.parse(mime(filename.toLowerCase()) ?? ''),
            ),
          );

    final completer = Completer<String>();
    if (cancelToken != null) {
      cancelToken.onCancel = _completeWithError(
        completer: completer,
        action: () => client.cancel(),
        cancelMessage: cancelToken.cancelMessage,
      );
    }

    resolveStreamedResponse(client.send())
        .then((data) => completer.complete(data['file'] as String))
        .catchError((e) {
      if (!completer.isCompleted) completer.completeError(e);
    });

    return completer.future;
  }

  /// Make upload to `/multipart` endpoint
  /// [maxConcurrentChunkRequests] maximum concurrent requests
  /// [cancelToken] make cancelable request
  Future<String> multipart(
    SharedFile file, {
    bool storeMode,
    ProgressListener onProgress,
    int maxConcurrentChunkRequests,
    CancelToken cancelToken,
  }) async {
    assert(file != null, 'The file cannot be null');
    maxConcurrentChunkRequests ??= options.multipartMaxConcurrentChunkRequests;

    final filename = file.name;
    final filesize = await file.length();
    final mimeType = file.mimeType;

    assert(filesize > _kRecomendedMaxFilesizeForBaseUpload,
        'Minimum file size to use with Multipart Uploads is 10MB');

    final completer = Completer<String>();

    final startTransaction = createMultipartRequest(
        'POST', buildUri('$uploadUrl/multipart/start/'), false)
      ..fields.addAll({
        'UPLOADCARE_PUB_KEY': publicKey,
        'UPLOADCARE_STORE': resolveStoreModeParam(storeMode),
        'filename': filename,
        'size': filesize.toString(),
        'content_type': mimeType,
        if (options.useSignedUploads) ..._signUpload(),
      });

    if (cancelToken != null) {
      cancelToken.onCancel = _completeWithError(
        completer: completer,
        action: () => startTransaction.cancel(),
        cancelMessage: cancelToken.cancelMessage,
      );
    }

    resolveStreamedResponse(startTransaction.send()).then((map) {
      final urls = (map['parts'] as List).cast<String>();
      final uuid = map['uuid'] as String;
      final inProgressActions = <UcRequest>[];

      ProgressEntity progress = ProgressEntity(0, filesize);

      if (onProgress != null) onProgress(progress);

      return Future.wait(List.generate(urls.length, (index) {
        final url = urls[index];
        final offset = index * _kChunkSize;
        final diff = filesize - offset;
        final bytesToRead = _kChunkSize < diff ? _kChunkSize : diff;

        return Future.value(() {
          if (cancelToken?.isCanceled ?? false) return null;

          return file
              .openRead(offset, offset + bytesToRead)
              .toList()
              .then((bytesList) => bytesList.expand((list) => list).toList())
              .then((bytes) => createRequest('PUT', buildUri(url), false)
                ..bodyBytes = bytes
                ..headers.addAll({
                  'Content-Type': mimeType,
                }))
              .then((request) {
            inProgressActions.add(request);

            return resolveStreamedResponseStatusCode(request.send())
                .then((response) {
              inProgressActions.remove(request);
              if (onProgress != null)
                onProgress(progress = progress.copyWith(
                  uploaded: progress.uploaded + bytesToRead,
                ));
              return response;
            });
          });
        });
      })).then((actions) {
        if (cancelToken != null)
          cancelToken.onCancel = _completeWithError(
            completer: completer,
            action: () =>
                inProgressActions.forEach((request) => request.cancel()),
            cancelMessage: cancelToken.cancelMessage,
          );
        return ConcurrentRunner(maxConcurrentChunkRequests, actions).run();
      }).then((_) {
        final finishTransaction = createMultipartRequest(
            'POST', buildUri('$uploadUrl/multipart/complete/'), false)
          ..fields.addAll({
            'UPLOADCARE_PUB_KEY': publicKey,
            'uuid': uuid,
            if (options.useSignedUploads) ..._signUpload(),
          });

        if (!completer.isCompleted)
          completer.complete(resolveStreamedResponse(finishTransaction.send())
              .then((_) => uuid));
      });
    }).catchError((e) {
      if (!completer.isCompleted) completer.completeError(e);
    });

    return completer.future;
  }

  /// Make upload to `/fromUrl` endpoint
  Future<String> fromUrl(
    String url, {
    bool storeMode,
    ProgressListener onProgress,
    Duration checkInterval = const Duration(seconds: 1),
  }) async {
    final request = createMultipartRequest(
      'POST',
      buildUri('$uploadUrl/from_url/'),
      false,
    )..fields.addAll({
        'pub_key': publicKey,
        'store': resolveStoreModeParam(storeMode),
        'source_url': url,
        if (options.useSignedUploads) ..._signUpload(),
      });

    final token =
        (await resolveStreamedResponse(request.send()))['token'] as String;

    String fileId;

    await for (UrlUploadStatusEntity response
        in _urlUploadStatusAsStream(token, checkInterval)) {
      if (response.status == UrlUploadStatusValue.Error)
        throw ClientException(response.errorMessage);

      if (response.status == UrlUploadStatusValue.Success)
        fileId = response.fileInfo.id;

      if (response.progress != null && onProgress != null)
        onProgress(response.progress);
    }

    return fileId;
  }

  Future<void> _statusTimerCallback(
    String token,
    Duration checkInterval,
    StreamController<UrlUploadStatusEntity> controller,
  ) async {
    final response = UrlUploadStatusEntity.fromJson(
      await resolveStreamedResponse(
        createRequest(
          'GET',
          buildUri(
            '$uploadUrl/from_url/status/',
            {
              'token': token,
            },
          ),
          false,
        ).send(),
      ),
    );

    controller.add(response);

    if (response.status == UrlUploadStatusValue.Progress) {
      return Timer(checkInterval,
          () => _statusTimerCallback(token, checkInterval, controller));
    }

    controller.close();
  }

  Stream<UrlUploadStatusEntity> _urlUploadStatusAsStream(
    String token,
    Duration checkInterval,
  ) {
    final StreamController<UrlUploadStatusEntity> controller =
        StreamController.broadcast();

    Timer(checkInterval,
        () => _statusTimerCallback(token, checkInterval, controller));

    return controller.stream;
  }

  Map<String, String> _signUpload() {
    final expire = DateTime.now()
            .add(options.signedUploadsSignatureLifetime)
            .millisecondsSinceEpoch ~/
        1000;

    final signature = md5.convert('$privateKey$expire'.codeUnits).toString();

    return {
      'signature': signature,
      'expire': expire.toString(),
    };
  }

  void Function() _completeWithError({
    @required Completer<String> completer,
    @required void Function() action,
    String cancelMessage,
  }) =>
      () {
        if (!completer.isCompleted) {
          action();
          completer.completeError(CancelUploadException(cancelMessage));
        }
      };

  Future<String> _runInIsolate(
    Object resource, {
    bool storeMode,
    ProgressListener onProgress,
    CancelToken cancelToken,
  }) {
    final poolSize = options.maxIsolatePoolSize;
    final isolateWorker = IsolateWorker(poolSize);

    return isolateWorker.upload(
      options: options,
      resource: resource,
      storeMode: storeMode,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }
}
