import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zip_multi/src/services/zip_multi_service.dart';

void main() {
  test('crée puis reconstruit un fichier fractionné v2', () async {
    final root = await Directory.systemTemp.createTemp('zipmulti_test_');
    try {
      final inputDir = Directory('${root.path}${Platform.pathSeparator}input')..createSync();
      final zipDir = Directory('${root.path}${Platform.pathSeparator}zips')..createSync();
      final outputDir = Directory('${root.path}${Platform.pathSeparator}output')..createSync();

      final bytes = List<int>.generate(
        1400 * 1024,
        (index) => (index * 73 + index ~/ 251) & 0xff,
        growable: false,
      );
      final source = File('${inputDir.path}${Platform.pathSeparator}gros-fichier.bin');
      await source.writeAsBytes(bytes, flush: true);

      final service = ZipMultiService();
      final created = await service.createVolumes(
        files: [source],
        outputDirectory: zipDir,
        baseName: 'test',
        maxBytes: 1024 * 1024,
        advancedSplit: true,
      );

      expect(created.volumes.length, greaterThanOrEqualTo(2));
      for (final volume in created.volumes) {
        expect(await volume.length(), lessThanOrEqualTo(1024 * 1024));
      }

      final extracted = await service.extractVolumes(
        selectedVolumes: [created.volumes.last],
        destination: outputDir,
      );

      expect(extracted.integrityVerified, isTrue);
      final rebuilt = File('${outputDir.path}${Platform.pathSeparator}gros-fichier.bin');
      expect(await rebuilt.exists(), isTrue);
      expect(await rebuilt.readAsBytes(), bytes);
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  });
}
