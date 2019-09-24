import 'dart:ui';

import 'package:dotenv/dotenv.dart';
import 'package:test/test.dart';
import 'package:uploadcare_client/src/client.dart';
import 'package:uploadcare_client/src/transformations/common.dart';
import 'package:uploadcare_client/src/transformations/image.dart';
import 'package:uploadcare_client/src/transformations/path_transformer.dart';
import 'package:uploadcare_client/src/transformations/video.dart';
import 'package:uploadcare_client/uploadcare_client.dart';

void main() {
  UploadcareClient client;

  setUpAll(() {
    load();

    client = UploadcareClient(
        options: ClientOptions(
      authorizationScheme: AuthSchemeSimple(
        apiVersion: 'v0.5',
        publicKey: env['UPLOADCARE_PUBLIC_KEY'],
        privateKey: env['UPLOADCARE_PRIVATE_KEY'],
      ),
    ));
  });

  test('test #1', () {
    final image = CdnImage('some-long-id')
      ..transform(ImageResizeTransformation(Size(300, 450)))
      ..transform(QualityTransformation())
      ..transform(ImageFormatTransformation(ImageFormatTValue.Webp))
      ..transform(CropTransformation(Size.square(64), Offset.zero));

    expect(
        image.uri.path,
        equals(
            '/some-long-id/-/resize/300x450/-/quality/normal/-/format/webp/-/crop/64x64/0,0/'));
  });

  test('test #2', () {
    final video = PathTransformer('some-long-id/video')
      ..transform(VideoResizeTransformation(Size(512, 384)))
      ..transform(VideoThumbsGenerateTransformation(10))
      ..transform(CutTransformation(
        const Duration(seconds: 109),
        length: Duration(
          seconds: 30,
        ),
      ))
      ..sort((a, b) => b is VideoThumbsGenerateTransformation ? -1 : 1);

    expect(
        video.path,
        equals(
            'some-long-id/video/-/cut/000:01:49/000:00:30/-/resize/512x384/-/thumbs~10/'));
  });

  test('test #3', () {
    final image = CdnImage('some-long-id');

    expect(image.pathTransformer.path, equals('some-long-id/'));
  });

  test('test #4', () {
    final group = CdnGroup('some-long-group-id~2');

    expect(group.pathTransformer.path, equals('some-long-group-id~2/'));

    final image = group.getImage(0)
      ..transform(ImageResizeTransformation(Size.square(66)));

    expect(
        image.url,
        equals(
            'https://ucarecdn.com/some-long-group-id~2/nth/0/-/resize/66x66/'));
  });

  test('test #5', () {
    final group = CdnGroup('some-long-group-id~2')
      ..transform(ArchiveTransformation(ArchiveTValue.Tar, 'archive.tar'))
      ..transform(ArchiveTransformation(ArchiveTValue.Zip, 'archive.zip'));

    expect(group.pathTransformer.path,
        equals('some-long-group-id~2/archive/tar/archive.tar/'));
  });
}