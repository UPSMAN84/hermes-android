import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/character_generation_context.dart';
import '../models/comfy_workflow.dart';
import '../models/generation_job.dart';
import '../services/generation_repository.dart';

abstract interface class ImagePickerPort {
  Future<File?> pickImage();
}

final class DefaultImagePickerPort implements ImagePickerPort {
  const DefaultImagePickerPort();

  @override
  Future<File?> pickImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    return file == null ? null : File(file.path);
  }
}

/// Renders form controls solely from [workflow]'s confirmed bindings and
/// submits an immutable [GenerationRequest] through [repository]. "Use
/// character context" is a one-time client-side prefill, not a flag sent to
/// the repository: composing directly into the visible, editable prompt
/// text (and pre-selecting the avatar file) keeps what's submitted always
/// exactly what's on screen, with no hidden server-side recomposition that
/// could double-apply the appearance prefix.
class GenerationForm extends StatefulWidget {
  const GenerationForm({
    super.key,
    required this.repository,
    required this.workflow,
    this.characterContext,
    this.sourceSessionId,
    this.sourceMessageId,
    this.sourceContextId,
    this.imagePicker = const DefaultImagePickerPort(),
    required this.onSubmitted,
  });

  final GenerationRepository repository;
  final ComfyWorkflowDefinition workflow;
  final CharacterGenerationContext? characterContext;
  final String? sourceSessionId;
  final String? sourceMessageId;
  final String? sourceContextId;
  final ImagePickerPort imagePicker;
  final void Function(GenerationJob job) onSubmitted;

  @override
  State<GenerationForm> createState() => _GenerationFormState();
}

class _GenerationFormState extends State<GenerationForm> {
  final Map<String, TextEditingController> _textControllers = {};
  final Map<String, bool> _toggleValues = {};
  final Map<String, String?> _enumValues = {};
  final Map<String, File?> _fileValues = {};
  bool _useCharacterContext = false;
  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    for (final binding in widget.workflow.bindings) {
      switch (binding.controlType) {
        case WorkflowControlType.toggle:
          _toggleValues[binding.id] = binding.defaultValue == true;
        case WorkflowControlType.enumeration:
          final defaultValue = binding.defaultValue?.toString();
          _enumValues[binding.id] =
              defaultValue != null && binding.choices.contains(defaultValue)
              ? defaultValue
              : (binding.choices.isEmpty ? null : binding.choices.first);
        case WorkflowControlType.file:
          break;
        case WorkflowControlType.text:
        case WorkflowControlType.multiline:
        case WorkflowControlType.integer:
        case WorkflowControlType.decimal:
          _textControllers[binding.id] = TextEditingController(
            text: binding.defaultValue?.toString() ?? '',
          );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  WorkflowInputBinding? _bindingByRole(BindingRole role) {
    for (final binding in widget.workflow.bindings) {
      if (binding.role == role) return binding;
    }
    return null;
  }

  void _toggleUseContext(bool value) {
    setState(() {
      _useCharacterContext = value;
      final context = widget.characterContext;
      if (!value || context == null) return;
      final promptBinding = _bindingByRole(BindingRole.prompt);
      if (promptBinding != null) {
        final controller = _textControllers[promptBinding.id];
        if (controller != null) {
          controller.text = composeGenerationPrompt(
            userPrompt: controller.text,
            context: context,
            useContext: true,
          );
        }
      }
      final imageBinding = _bindingByRole(BindingRole.inputImage);
      final avatarPath = context.referenceImagePath;
      if (imageBinding != null && avatarPath != null) {
        _fileValues[imageBinding.id] = File(avatarPath);
      }
    });
  }

  Future<void> _pickFile(WorkflowInputBinding binding) async {
    final file = await widget.imagePicker.pickImage();
    if (file == null) return;
    setState(() => _fileValues[binding.id] = file);
  }

  bool _isRequiredSatisfied(WorkflowInputBinding binding) {
    switch (binding.controlType) {
      case WorkflowControlType.file:
        return _fileValues[binding.id] != null;
      case WorkflowControlType.toggle:
        return true;
      case WorkflowControlType.enumeration:
        return (_enumValues[binding.id] ?? '').isNotEmpty;
      case WorkflowControlType.text:
      case WorkflowControlType.multiline:
      case WorkflowControlType.integer:
      case WorkflowControlType.decimal:
        return (_textControllers[binding.id]?.text.trim() ?? '').isNotEmpty;
    }
  }

  bool _isRangeSatisfied(WorkflowInputBinding binding) {
    if (binding.controlType != WorkflowControlType.integer &&
        binding.controlType != WorkflowControlType.decimal) {
      return true;
    }
    final text = _textControllers[binding.id]?.text.trim() ?? '';
    if (text.isEmpty) return !binding.required;
    final value = num.tryParse(text);
    if (value == null) return false;
    if (binding.minimum != null && value < binding.minimum!) return false;
    if (binding.maximum != null && value > binding.maximum!) return false;
    return true;
  }

  bool get _isValid {
    for (final binding in widget.workflow.bindings) {
      if (binding.required && !_isRequiredSatisfied(binding)) return false;
      if (!_isRangeSatisfied(binding)) return false;
    }
    return true;
  }

  /// Names the first binding blocking submission, so a disabled Generate
  /// button never looks like it's simply doing nothing.
  String? get _invalidReason {
    for (final binding in widget.workflow.bindings) {
      if (binding.required && !_isRequiredSatisfied(binding)) {
        return '"${binding.label}" is required.';
      }
      if (!_isRangeSatisfied(binding)) {
        return '"${binding.label}" has an invalid value.';
      }
    }
    return null;
  }

  Object? _valueFor(WorkflowInputBinding binding) {
    switch (binding.controlType) {
      case WorkflowControlType.file:
        return null;
      case WorkflowControlType.toggle:
        return _toggleValues[binding.id] ?? (binding.defaultValue == true);
      case WorkflowControlType.enumeration:
        return _enumValues[binding.id];
      case WorkflowControlType.integer:
        final text = _textControllers[binding.id]?.text.trim() ?? '';
        if (text.isEmpty) return null;
        return int.tryParse(text) ?? num.tryParse(text)?.toInt() ?? text;
      case WorkflowControlType.decimal:
        final text = _textControllers[binding.id]?.text.trim() ?? '';
        if (text.isEmpty) return null;
        return double.tryParse(text) ?? text;
      case WorkflowControlType.text:
      case WorkflowControlType.multiline:
        return _textControllers[binding.id]?.text ?? '';
    }
  }

  Future<void> _submit() async {
    if (_submitting || !_isValid) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final values = <String, Object?>{};
      for (final binding in widget.workflow.bindings) {
        final value = _valueFor(binding);
        if (value != null) values[binding.id] = value;
      }
      final referenceImages = <String, File>{
        for (final entry in _fileValues.entries)
          if (entry.value != null) entry.key: entry.value!,
      };
      final job = await widget.repository.submit(
        GenerationRequest(
          workflowId: widget.workflow.id,
          kind: widget.workflow.kind,
          submittedValues: values,
          sourceSessionId: widget.sourceSessionId,
          sourceMessageId: widget.sourceMessageId,
          sourceContextId: widget.sourceContextId,
          referenceImages: referenceImages,
        ),
      );
      if (!mounted) return;
      widget.onSubmitted(job);
    } catch (error) {
      if (!mounted) return;
      setState(() => _submitError = 'Submit failed: $error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _buildBinding(WorkflowInputBinding binding) {
    switch (binding.controlType) {
      case WorkflowControlType.text:
        return TextField(
          key: Key('binding-${binding.id}'),
          controller: _textControllers[binding.id],
          decoration: InputDecoration(labelText: binding.label),
          onChanged: (_) => setState(() {}),
        );
      case WorkflowControlType.multiline:
        return TextField(
          key: Key('binding-${binding.id}'),
          controller: _textControllers[binding.id],
          decoration: InputDecoration(labelText: binding.label),
          minLines: 2,
          maxLines: 6,
          onChanged: (_) => setState(() {}),
        );
      case WorkflowControlType.integer:
      case WorkflowControlType.decimal:
        return TextField(
          key: Key('binding-${binding.id}'),
          controller: _textControllers[binding.id],
          decoration: InputDecoration(
            labelText: binding.label,
            helperText: binding.minimum != null || binding.maximum != null
                ? '${binding.minimum ?? '-'} to ${binding.maximum ?? '-'}'
                : null,
          ),
          keyboardType: TextInputType.numberWithOptions(
            decimal: binding.controlType == WorkflowControlType.decimal,
          ),
          onChanged: (_) => setState(() {}),
        );
      case WorkflowControlType.toggle:
        return SwitchListTile(
          key: Key('binding-${binding.id}'),
          title: Text(binding.label),
          value: _toggleValues[binding.id] ?? false,
          onChanged: (value) =>
              setState(() => _toggleValues[binding.id] = value),
        );
      case WorkflowControlType.enumeration:
        return DropdownButtonFormField<String>(
          key: Key('binding-${binding.id}'),
          initialValue: _enumValues[binding.id],
          isExpanded: true,
          decoration: InputDecoration(labelText: binding.label),
          items: [
            for (final choice in binding.choices)
              DropdownMenuItem(value: choice, child: Text(choice)),
          ],
          onChanged: (value) => setState(() => _enumValues[binding.id] = value),
        );
      case WorkflowControlType.file:
        final file = _fileValues[binding.id];
        return Row(
          key: Key('binding-${binding.id}'),
          children: [
            Expanded(
              child: Text(
                file == null ? '${binding.label}: none selected' : file.path,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () => _pickFile(binding),
              child: const Text('Choose image'),
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final promptBinding = _bindingByRole(BindingRole.prompt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.characterContext != null)
          CheckboxListTile(
            key: const Key('use-character-context'),
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Use character context'),
            value: _useCharacterContext,
            onChanged: (value) => _toggleUseContext(value ?? false),
          ),
        for (final binding in widget.workflow.bindings) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _buildBinding(binding),
          ),
        ],
        if (promptBinding != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              _textControllers[promptBinding.id]?.text ?? '',
              key: const Key('composed-prompt-preview'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_submitError != null)
          Text(
            _submitError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_submitError == null && !_isValid && _invalidReason != null)
          Text(
            _invalidReason!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _isValid && !_submitting ? _submit : null,
          child: Text(_submitting ? 'Generating…' : 'Generate'),
        ),
      ],
    );
  }
}
