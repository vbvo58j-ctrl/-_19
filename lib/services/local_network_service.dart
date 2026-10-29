import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bluetooth_classic_service.dart';

/// Local Wi-Fi/LAN transport. It discovers peers on the same broadcast
/// domain and transfers newline-delimited JSON packets over TCP.
/// This is a transport path, not an Internet relay or end-to-end encryption.
class LocalNetworkService {
  LocalNetworkService._();
  static final LocalNetworkService instance = LocalNetworkService._();

  static const int _discoveryPort = 39772;
  static const int _tcpPort = 39771;
  // Hard cap for newline-delimited JSON frames. Disconnect oversized peers
  // before buffering unbounded input in LineSplitter.
  static const int maxFrameBytes = 1024 * 1024;
  final StreamController<BlousabEvent> _events =
      StreamController<BlousabEvent>.broadcast();
  final Map<String, _LanPeer> _peers = <String, _LanPeer>{};

  RawDatagramSocket? _udp;
  ServerSocket? _server;
  Timer? _discoveryTimer;
  String _userId = '';
  String _userName = 'مستخدم بلوساب';
  bool _running = false;

  Stream<BlousabEvent> get events => _events.stream;
  bool get isRunning => _running;
  int get peerCount => _peers.length;
  List<Map<String, String>> get discoveredPeers => _peers.values.map((p) => <String, String>{'id': p.id, 'name': p.name, 'address': p.address}).toList(growable: false);

  Future<void> start({required String userId, required String userName}) async {
    _userId = userId;
    _userName = userName;
    if (_running) {
      _sendDiscovery();
      return;
    }
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _tcpPort,
          shared: true);
      _server!.listen(_acceptClient, onError: (Object error) {
        _emitError('تعذر استقبال اتصال الشبكة المحلية: $error');
      });
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4,
          _discoveryPort,
          reuseAddress: true, reusePort: true);
      _udp!.broadcastEnabled = true;
      _udp!.listen(_onUdpEvent, onError: (Object error) {
        _emitError('تعذر اكتشاف أجهزة الشبكة المحلية: $error');
      });
      _running = true;
      _sendDiscovery();
      _discoveryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _sendDiscovery();
        _prunePeers();
      });
      _events.add(const BlousabEvent(type: 'lanStarted'));
    } catch (e) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _running = false;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _udp?.close();
    _udp = null;
    await _server?.close();
    _server = null;
    _peers.clear();
    _events.add(const BlousabEvent(type: 'lanStopped'));
  }

  void _sendDiscovery() {
    final udp = _udp;
    if (!_running || udp == null) return;
    final bytes = utf8.encode(jsonEncode({
      'kind': 'blousab_discovery',
      'peerId': _userId,
      'name': _userName,
      'port': _tcpPort,
    }));
    try {
      udp.send(bytes, InternetAddress('255.255.255.255'), _discoveryPort);
    } catch (_) {}
  }

  void _onUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final udp = _udp;
    if (udp == null) return;
    Datagram? datagram;
    while ((datagram = udp.receive()) != null) {
      try {
        final packet = jsonDecode(utf8.decode(datagram!.data));
        if (packet is! Map || packet['peerId']?.toString() == _userId) continue;
        final kind = packet['kind']?.toString();
        final address = datagram!.address.address;
        if (kind == 'blousab_discovery') {
          final peerId = packet['peerId']?.toString() ?? '';
          if (peerId.isEmpty) continue;
          final wasKnown = _peers.containsKey(peerId);
          _peers[peerId] = _LanPeer(
            id: peerId,
            name: packet['name']?.toString() ?? 'جهاز على الشبكة',
            address: address,
            lastSeen: DateTime.now(),
          );
          if (!wasKnown) _events.add(BlousabEvent(type: 'peerDiscovered', name: packet['name']?.toString() ?? 'جهاز على الشبكة', address: 'lan:$address', message: peerId));
          final reply = utf8.encode(jsonEncode({
            'kind': 'blousab_peer',
            'peerId': _userId,
            'name': _userName,
            'port': _tcpPort,
          }));
          udp.send(reply, datagram!.address, _discoveryPort);
        } else if (kind == 'blousab_peer') {
          final peerId = packet['peerId']?.toString() ?? '';
          if (peerId.isEmpty) continue;
          final wasKnown = _peers.containsKey(peerId);
          _peers[peerId] = _LanPeer(
            id: peerId,
            name: packet['name']?.toString() ?? 'جهاز على الشبكة',
            address: address,
            lastSeen: DateTime.now(),
          );
          if (!wasKnown) _events.add(BlousabEvent(type: 'peerDiscovered', name: packet['name']?.toString() ?? 'جهاز على الشبكة', address: 'lan:$address', message: peerId));
        }
      } catch (_) {}
    }
  }

  void _prunePeers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    _peers.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
  }

  void _acceptClient(Socket socket) {
    final address = socket.remoteAddress.address;
    final buffer = <int>[];
    var closed = false;
    void rejectOversizedFrame() {
      if (closed) return;
      closed = true;
      socket.destroy();
    }

    socket.listen((chunk) {
      if (closed) return;
      for (final byte in chunk) {
        if (byte == 10) { // LF: one complete JSON frame
          if (buffer.isNotEmpty && buffer.last == 13) buffer.removeLast();
          final frame = List<int>.from(buffer);
          buffer.clear();
          try {
            final line = utf8.decode(frame, allowMalformed: false);
            _events.add(BlousabEvent(
              type: 'message',
              address: 'lan:$address',
              name: 'شبكة محلية',
              message: line,
            ));
          } catch (_) {
            // Ignore malformed UTF-8 frames; never pass them to JSON handlers.
          }
        } else {
          buffer.add(byte);
          if (buffer.length > maxFrameBytes) {
            rejectOversizedFrame();
            return;
          }
        }
      }
    }, onError: (Object error) {
      _emitError('خطأ في اتصال الشبكة المحلية: $error');
      socket.destroy();
    }, onDone: () => socket.destroy());
  }

  /// Sends a packet only to the peer explicitly selected by the user.
  /// The peer must still be present in the live discovery list; stale saved
  /// addresses are never treated as an active connection.
  Future<void> sendMessageToPeer({required String address, required String payload}) async {
    if (!_running) throw StateError('الشبكة المحلية غير مفعلة');
    if (utf8.encode(payload).length > maxFrameBytes) {
      throw ArgumentError('حجم الحزمة يتجاوز الحد المسموح (1 MiB)');
    }
    final matches = _peers.values.where((p) => p.address == address);
    final peer = matches.isEmpty ? null : matches.first;
    if (peer == null) {
      throw StateError('الجهاز المحدد لم يعد ظاهرًا على الشبكة؛ حدّث البحث واختره مجددًا');
    }
    Socket? socket;
    try {
      socket = await Socket.connect(peer.address, _tcpPort,
          timeout: const Duration(seconds: 4));
      socket.write('$payload\n');
      await socket.flush();
    } catch (e) {
      throw StateError('تعذر الإرسال إلى ${peer.name} عبر Wi-Fi: $e');
    } finally {
      try { await socket?.close(); } catch (_) { socket?.destroy(); }
    }
  }

  /// Sends an acknowledgement or control packet to a live LAN address.
  /// The address comes from the remote TCP connection event (lan:IPv4).
  Future<void> sendControlPacket({required String address, required String payload}) async {
    if (!_running) throw StateError('الشبكة المحلية غير مفعلة');
    if (utf8.encode(payload).length > maxFrameBytes) {
      throw ArgumentError('حجم الحزمة يتجاوز الحد المسموح (1 MiB)');
    }
    final host = address.startsWith('lan:') ? address.substring(4) : address;
    final ip = InternetAddress.tryParse(host);
    if (ip == null) throw ArgumentError('عنوان شبكة غير صالح');
    Socket? socket;
    try {
      socket = await Socket.connect(ip, _tcpPort, timeout: const Duration(seconds: 4));
      socket.write('$payload\n');
      await socket.flush();
    } finally {
      try { await socket?.close(); } catch (_) { socket?.destroy(); }
    }
  }

  Future<void> broadcastMessage(String payload) async {
    if (!_running) throw StateError('الشبكة المحلية غير مفعلة');
    if (utf8.encode(payload).length > maxFrameBytes) {
      throw ArgumentError('حجم الحزمة يتجاوز الحد المسموح (1 MiB)');
    }
    if (_peers.isEmpty) throw StateError('لم يُعثر على أجهزة أخرى في الشبكة المحلية');
    final targets = _peers.values.toList(growable: false);
    var sent = 0;
    Object? lastError;
    for (final peer in targets) {
      Socket? socket;
      try {
        socket = await Socket.connect(peer.address, _tcpPort,
            timeout: const Duration(seconds: 3));
        socket.write('$payload\n');
        await socket.flush();
        sent++;
      } catch (e) {
        lastError = e;
      } finally {
        try { await socket?.close(); } catch (_) { socket?.destroy(); }
      }
    }
    if (sent == 0) throw StateError('تعذر الإرسال عبر الشبكة المحلية: $lastError');
  }

  void _emitError(String message) {
    _events.add(BlousabEvent(type: 'lanError', message: message));
  }
}

class _LanPeer {
  final String id;
  final String name;
  final String address;
  DateTime lastSeen;
  _LanPeer({required this.id, required this.name, required this.address, required this.lastSeen});
}