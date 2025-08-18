// Copyright 2021 MongoDB, Inc.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:args/command_runner.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as path;

import '../common/target_os_type.dart';
import '../common/archive.dart';
import 'options.dart';

class InstallCommand extends Command<void> {
  static const versionFileName = 'realm_version.txt';

  @override
  final description = 'Download & install Realm native binaries into a Flutter or Dart project';

  @override
  final name = 'install';

  late Options options;

  late Pubspec pubspec;
  late final debug = options.debug;
  late final flavor = options.flavor!;
  late final force = options.force; // not used!?!
  late final targetOsType = options.targetOsType!;

  InstallCommand() {
    pubspec = parsePubspec(File('pubspec.yaml'));
    final defaultFlavor = pubspec.dependencies['flutter'] == null ? Flavor.dart : Flavor.flutter; // default depends on project type
    populateOptionsParser(
      argParser,
      targetOsTypeDefaultOverride: Platform.operatingSystem.asTargetOsType,
      flavorDefaultOverride: defaultFlavor,
    );
  }

  Directory getBinaryPath(Directory realmPackagePath, Flavor flavor) {
    final root = realmPackagePath.path;
    return switch (flavor) {
      Flavor.dart => Directory(path.join(root, 'binary', targetOsType.name)),
      Flavor.flutter => Directory(switch (targetOsType) {
          TargetOsType.android => path.join(root, 'android', 'src', 'main', 'cpp', 'lib'),
          TargetOsType.ios => path.join(root, 'ios'),
          TargetOsType.macos => path.join(root, 'macos'),
          TargetOsType.linux => path.join(root, 'linux', 'binary', 'linux'),
          TargetOsType.windows => path.join(root, 'windows', 'binary', 'windows'),
        }),
    };
  }

  Future<bool> shouldSkipDownload(String binariesPath, String expectedVersion) async {
    try {
      final versionsFile = File(path.join(binariesPath, versionFileName));
      if (await versionsFile.exists()) {
        final existingVersion = await versionsFile.readAsString();
        if (expectedVersion == existingVersion) {
          print('Realm binaries for $expectedVersion already downloaded');
          return true;
        }
      }
    } catch (e) {
      // If we can't read the version file, assume we need to download
      print('Could not read version file, will download binaries: $e');
    }
    return false;
  }

  Future<void> downloadAndExtractBinaries(Directory destinationDir, Version version, String archiveName) async {
    // Use a lock file to prevent concurrent downloads to the same location
    final lockFile = File(path.join(destinationDir.absolute.path, '.realm_install.lock'));
    
    // Check if another process is currently installing
    if (await lockFile.exists()) {
      print('Another install process is running, waiting...');
      var attempts = 0;
      while (await lockFile.exists() && attempts < 30) { // Wait up to 30 seconds
        await Future.delayed(Duration(seconds: 1));
        attempts++;
      }
      if (await lockFile.exists()) {
        print('Warning: Lock file still exists after waiting, proceeding anyway...');
        try {
          await lockFile.delete();
        } catch (e) {
          print('Could not delete lock file: $e');
        }
      }
    }
    
    if (await shouldSkipDownload(destinationDir.absolute.path, version.toString())) {
      return;
    }

    // Create lock file
    try {
      if (!await destinationDir.exists()) {
        await destinationDir.create(recursive: true);
      }
      await lockFile.writeAsString('${DateTime.now().toIso8601String()}\n${Platform.resolvedExecutable}');
    } catch (e) {
      if (e is PathExistsException) {
        // Directory was created by another process, continue
        print('Directory ${destinationDir.absolute.path} already exists, continuing...');
      } else {
        rethrow;
      }
    }

    final destinationFile = File(path.join(Directory.systemTemp.createTempSync('realm-binary-').absolute.path, archiveName));
    if (!await destinationFile.parent.exists()) {
      await destinationFile.parent.create(recursive: true);
    }

    try {
      print('Downloading Realm binaries for $version to ${destinationFile.absolute.path}');
      final client = HttpClient();
      var url = 'https://static.realm.io/downloads/dart/${Uri.encodeComponent(version.toString())}/$archiveName';
      if (debug) {
        url = 'http://localhost:8000/$archiveName';
      }
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode >= 400) {
          throw Exception('Error downloading Realm binaries from $url. Error code: ${response.statusCode}');
        }
        await response.pipe(destinationFile.openWrite());
      }
      // TODO: Handle download errors in Install command catch https://github.com/realm/realm-dart/issues/696.
      finally {
        client.close(force: true);
      }

      print('Extracting Realm binaries to ${destinationDir.absolute.path}');
      
      // Clean up any existing incomplete installation
      try {
        final versionFile = File(path.join(destinationDir.absolute.path, versionFileName));
        if (await versionFile.exists()) {
          await versionFile.delete();
        }
      } catch (e) {
        print('Warning: Could not clean up existing version file: $e');
      }
      
      final archive = Archive();
      await archive.extract(destinationFile, destinationDir);

      final versionFile = File(path.join(destinationDir.absolute.path, versionFileName));
      await versionFile.writeAsString(version.toString());
    } finally {
      // Clean up lock file
      try {
        if (await lockFile.exists()) {
          await lockFile.delete();
        }
      } catch (e) {
        print('Warning: Could not clean up lock file: $e');
      }
    }
  }

  Future<Directory> getPackagePath(String name) async {
    final packageConfig = await findPackageConfig(Directory.current);
    if (packageConfig == null) {
      abort('Run `dart pub get`');
    }
    final package = packageConfig[name];
    if (package == null) {
      abort('$name package not found in dependencies. Add $name package to your pubspec.yaml');
    }
    return Directory.fromUri(package.root);
  }

  Pubspec parsePubspec(File file) {
    try {
      return Pubspec.parse(file.readAsStringSync(), sourceUrl: file.uri);
    } catch (e) {
      abort('Error parsing package pubspec at ${file.parent}. Error $e');
    }
  }

  @override
  FutureOr<void> run() async {
    options = parseOptionsResult(argResults!);

    final flavorName = flavor.packageName;
    final realmDependency = pubspec.dependencyOverrides[flavorName] ?? pubspec.dependencies[flavorName];
    print(pubspec.dependencyOverrides.values.join('\n'));
    print(realmDependency);
    if (realmDependency is PathDependency) {
      print('Path dependency for $flavorName found. Skipping install of native lib (assuming local development)');
      return;
    }
    if (realmDependency == null) {
      abort('Package $flavorName not found in dependencies. Add $flavorName package to your pubspec.yaml');
      // TODO: Should we just add it for them? What about the version?
    }

    final realmPackagePath = await getPackagePath(flavorName);
    final realmPubspec = parsePubspec(File(path.join(realmPackagePath.path, "pubspec.yaml")));

    final binaryPath = getBinaryPath(realmPackagePath, flavor);
    print(binaryPath);
    final archiveName = '${targetOsType.name}.tar.gz';
    await downloadAndExtractBinaries(binaryPath, realmPubspec.version!, archiveName);

    print('Realm install command finished.');
  }

  Never abort(String error) {
    print(error);
    print(usage);
    exit(64); //usage error
  }
}
