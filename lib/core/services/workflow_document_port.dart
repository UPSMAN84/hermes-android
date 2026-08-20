import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

final class ImportedWorkflowDocument {
  const ImportedWorkflowDocument({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;
}

abstract interface class WorkflowDocumentPort {
  /// Returns null when the user cancels the picker. Throws [FormatException]
  /// when the picked file exceeds [FilePickerWorkflowDocumentPort.maxBytes]
  /// -- checked from the file's reported length before its bytes are ever
  /// read into memory.
  Future<ImportedWorkflowDocument?> pickJson();

  Future<void> saveJson({required String fileName, required Uint8List bytes});
}

abstract interface class ExternalUriLauncher {
  /// Returns false when nothing on the device can handle [uri] (no browser
  /// installed/registered) rather than throwing, so callers can fall back to
  /// [UriClipboardPort].
  Future<bool> open(Uri uri);
}

abstract interface class UriClipboardPort {
  Future<void> copy(Uri uri);
}

final class FilePickerWorkflowDocumentPort implements WorkflowDocumentPort {
  const FilePickerWorkflowDocumentPort({this.maxBytes = 5 * 1024 * 1024});

  final int maxBytes;

  @override
  Future<ImportedWorkflowDocument?> pickJson() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null) return null;
    final length = await file.length();
    if (length > maxBytes) {
      throw FormatException('Workflow JSON exceeds the $maxBytes bytes limit');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw FormatException('Workflow JSON exceeds the $maxBytes bytes limit');
    }
    return ImportedWorkflowDocument(fileName: file.name, bytes: bytes);
  }

  @override
  Future<void> saveJson({
    required String fileName,
    required Uint8List bytes,
  }) async {
    await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: 'application/json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
  }
}

final class UrlLauncherExternalUriLauncher implements ExternalUriLauncher {
  const UrlLauncherExternalUriLauncher();

  @override
  Future<bool> open(Uri uri) async {
    try {
      return await launcher.launchUrl(
        uri,
        mode: launcher.LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }
}

final class ClipboardUriPort implements UriClipboardPort {
  const ClipboardUriPort();

  @override
  Future<void> copy(Uri uri) =>
      Clipboard.setData(ClipboardData(text: uri.toString()));
}
