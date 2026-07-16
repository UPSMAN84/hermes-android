// Full-screen phone-call UI bound to a [CallController]. Hands-free: the
// controller runs the listen->send->speak loop; this screen only renders state
// and exposes mute / speaker / hang-up. Reached from the chat app bar.
import 'package:flutter/material.dart';

import '../services/call_controller.dart';
import '../services/connection_manager.dart';

class CallScreen extends StatefulWidget {
  final SavedConnection connection;
  final Session session;

  const CallScreen({
    required this.connection,
    required this.session,
    super.key,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final CallController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CallController(
      connection: widget.connection,
      session: widget.session,
    );
    _controller.addListener(_onChanged);
    _controller.start();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _hangUp() async {
    await _controller.hangUp();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            _Avatar(title: widget.session.title),
            const SizedBox(height: 24),
            Text(
              widget.session.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            _StateLabel(state: state, status: _controller.status),
            const Spacer(flex: 3),
            _CallControls(
              state: state,
              muted: _controller.muted,
              speakerOn: _controller.speakerOn,
              onToggleMute: () =>
                  _controller.setMuted(!_controller.muted),
              onToggleSpeaker: _controller.toggleSpeaker,
              onHangUp: _hangUp,
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String title;
  const _Avatar({required this.title});

  @override
  Widget build(BuildContext context) {
    final initial =
        title.trim().isEmpty ? 'H' : title.trim().substring(0, 1).toUpperCase();
    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFD4AF37), Color(0xFF8C7A2E)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD4AF37).withValues(alpha: 0.3),
            blurRadius: 32,
            spreadRadius: 2,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 52,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _StateLabel extends StatelessWidget {
  final CallState state;
  final String? status;
  const _StateLabel({required this.state, required this.status});

  String get _label {
    switch (state) {
      case CallState.connecting:
        return 'Connecting…';
      case CallState.listening:
        return 'Listening…';
      case CallState.thinking:
        return 'Thinking…';
      case CallState.speaking:
        return 'Speaking…';
      case CallState.error:
        return status ?? 'Unavailable';
    }
  }

  Color get _color {
    switch (state) {
      case CallState.error:
        return Colors.redAccent;
      case CallState.connecting:
      case CallState.listening:
        return const Color(0xFFD4AF37);
      case CallState.thinking:
        return Colors.lightBlueAccent;
      case CallState.speaking:
        return Colors.greenAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state != CallState.error) ...[
          _PulseDot(color: _color),
          const SizedBox(width: 10),
        ],
        Text(
          _label,
          style: TextStyle(
            color: _color,
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1.0).animate(_anim),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _CallControls extends StatelessWidget {
  final CallState state;
  final bool muted;
  final bool speakerOn;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleSpeaker;
  final VoidCallback onHangUp;

  const _CallControls({
    required this.state,
    required this.muted,
    required this.speakerOn,
    required this.onToggleMute,
    required this.onToggleSpeaker,
    required this.onHangUp,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ControlButton(
          icon: muted ? Icons.mic_off : Icons.mic,
          label: muted ? 'Unmute' : 'Mute',
          onPressed: onToggleMute,
        ),
        _HangUpButton(onPressed: onHangUp),
        _ControlButton(
          icon: speakerOn ? Icons.volume_up : Icons.volume_off,
          label: 'Speaker',
          onPressed: onToggleSpeaker,
        ),
      ],
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onPressed,
          iconSize: 30,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.12),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.all(16),
          ),
          icon: Icon(icon),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}

class _HangUpButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _HangUpButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onPressed,
          iconSize: 36,
          style: IconButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.all(20),
          ),
          icon: const Icon(Icons.call_end),
        ),
        const SizedBox(height: 8),
        const Text(
          'End',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}
