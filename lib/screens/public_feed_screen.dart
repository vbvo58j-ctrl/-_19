import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../services/local_network_service.dart';
import 'chat_screen.dart';

/// Nearby public feed. Media is compressed before storage/transfer. LAN delivery
/// works only while both devices are on the same reachable Wi-Fi network.
class PublicFeedScreen extends StatefulWidget {
  final String userName;
  final String profilePhotoPath;
  const PublicFeedScreen({super.key, required this.userName, required this.profilePhotoPath});

  @override
  State<PublicFeedScreen> createState() => _PublicFeedScreenState();
}

class _PublicFeedScreenState extends State<PublicFeedScreen> {
  static const _key = 'blousab_public_feed_v1';
  static const _friendsKey = 'blousab_accepted_friends_v1';
  static const _requestsKey = 'blousab_friend_requests_v1';
  final _picker = ImagePicker();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _posts = [];
  StreamSubscription? _subscription;
  bool _busy = false;
  bool _loading = true;
  String? _loadError;
  bool _randomOrder = false;
  int _shuffleSeed = DateTime.now().millisecondsSinceEpoch;
  String _myId = 'blousab-user';
  Set<String> _friends = <String>{};
  List<Map<String, dynamic>> _friendRequests = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load().then((_) => _requestFeedSync()).catchError((_) { if (mounted) setState(() { _loading = false; _loadError = 'تعذر تحميل الخلاصة المحفوظة.'; }); });
    _subscription = LocalNetworkService.instance.events.listen(_onLanEvent);
  }

  @override
  void dispose() { _subscription?.cancel(); _scroll.dispose(); super.dispose(); }

  Future<Directory> _feedDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/blousab_public_feed');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _myId = prefs.getString('wasl_user_id') ?? '';
    if (_myId.trim().isEmpty || _myId == 'blousab-user') {
      _myId = 'blousab-${DateTime.now().microsecondsSinceEpoch}-${DateTime.now().millisecondsSinceEpoch.remainder(100000)}';
      await prefs.setString('wasl_user_id', _myId);
    }
    _friends = (prefs.getStringList(_friendsKey) ?? <String>[]).toSet();
    _friendRequests = (prefs.getStringList(_requestsKey) ?? <String>[])
        .map((item) { try { return Map<String, dynamic>.from(jsonDecode(item) as Map); } catch (_) { return <String, dynamic>{}; } })
        .where((item) => item.isNotEmpty).toList();
    final raw = prefs.getStringList(_key) ?? <String>[];
    final byId = <String, Map<String, dynamic>>{};
    for (final item in raw) {
      try {
        final post = Map<String, dynamic>.from(jsonDecode(item) as Map);
        final id = post['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        // One canonical entry per post ID; retain the newest copy if storage
        // contains a replayed duplicate.
        final existing = byId[id];
        final incomingUpdated = (post['updatedAt'] as num?)?.toInt() ?? (post['createdAt'] as num?)?.toInt() ?? 0;
        final existingUpdated = (existing?['updatedAt'] as num?)?.toInt() ?? (existing?['createdAt'] as num?)?.toInt() ?? 0;
        if (existing == null || incomingUpdated >= existingUpdated) byId[id] = post;
      } catch (_) {}
    }
    final posts = byId.values.toList();
    _sortPosts(posts);
    if (mounted) setState(() { _posts = posts; _loading = false; _loadError = null; });
  }

  void _sortPosts(List<Map<String, dynamic>> posts) {
    if (_randomOrder) {
      // Stable shuffle for the current view; tapping shuffle changes the seed.
      posts.sort((a, b) => _shuffleKey(a['id']?.toString() ?? '').compareTo(_shuffleKey(b['id']?.toString() ?? '')));
    } else {
      posts.sort((a, b) => ((b['createdAt'] as num?)?.toInt() ?? 0).compareTo((a['createdAt'] as num?)?.toInt() ?? 0));
    }
  }

  int _shuffleKey(String id) {
    var hash = _shuffleSeed;
    for (final unit in id.codeUnits) { hash = ((hash * 31) ^ unit) & 0x7fffffff; }
    return hash;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    // Persist canonical unique posts in chronological order, independent of
    // the currently selected display ordering.
    final unique = <String, Map<String, dynamic>>{};
    for (final post in _posts) {
      final id = post['id']?.toString() ?? '';
      if (id.isNotEmpty) unique[id] = post;
    }
    final stored = unique.values.toList()..sort((a, b) => ((b['createdAt'] as num?)?.toInt() ?? 0).compareTo((a['createdAt'] as num?)?.toInt() ?? 0));
    await prefs.setStringList(_key, stored.map(jsonEncode).toList());
  }

  Future<void> _refreshFeed() async {
    if (mounted) setState(() { _loading = true; _loadError = null; });
    try {
      await _load();
      await _requestFeedSync();
    } catch (_) {
      if (mounted) setState(() { _loading = false; _loadError = 'تعذر تحديث الخلاصة. حاول مرة أخرى.'; });
    }
  }

  void _toggleOrder() {
    setState(() {
      _randomOrder = !_randomOrder;
      _shuffleSeed = DateTime.now().microsecondsSinceEpoch;
      _sortPosts(_posts);
    });
  }

  Future<void> _requestFeedSync() async {
    try {
      if (LocalNetworkService.instance.isRunning) {
        await LocalNetworkService.instance.broadcastMessage(jsonEncode({
          'type': 'public_feed_sync_request', 'requesterId': _myId,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        }));
      }
    } catch (_) {}
  }

  Future<void> _broadcastPost(Map<String, dynamic> post) async {
    if (!LocalNetworkService.instance.isRunning) return;
    final outgoing = Map<String, dynamic>.from(post);
    outgoing.remove('mediaPath');
    outgoing.remove('profilePhotoPath');
    final mediaPath = post['mediaPath']?.toString() ?? '';
    if (mediaPath.isNotEmpty) {
      try {
        final file = File(mediaPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.length <= 4 * 1024 * 1024) {
            outgoing['mediaBase64'] = base64Encode(bytes);
          } else { outgoing['mediaOmitted'] = true; }
        }
      } catch (_) {}
    }
    final profilePath = post['profilePhotoPath']?.toString().isNotEmpty == true
        ? post['profilePhotoPath'].toString() : widget.profilePhotoPath;
    if (profilePath.isNotEmpty) {
      try {
        final file = File(profilePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.length <= 80 * 1024) outgoing['profilePhotoBase64'] = base64Encode(bytes);
        }
      } catch (_) {}
    }
    await LocalNetworkService.instance.broadcastMessage(
      jsonEncode({'type': 'public_feed_post', 'post': outgoing}),
    );
  }

  Future<void> _broadcastPostUpdate(Map<String, dynamic> post) async {
    try {
      if (!LocalNetworkService.instance.isRunning) return;
      await LocalNetworkService.instance.broadcastMessage(jsonEncode({
        'type': 'public_feed_update', 'postId': post['id'],
        'likes': post['likes'] ?? <String>[],
        'comments': post['comments'] ?? <Map<String, dynamic>>[],
        'updatedAt': (post['updatedAt'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  Future<void> _persistFriends() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_friendsKey, _friends.toList());
  }

  Future<void> _persistFriendRequests() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_requestsKey, _friendRequests.map(jsonEncode).toList());
  }

  Future<void> _acceptFriendRequest(Map<String, dynamic> request) async {
    final peerId = request['senderId']?.toString() ?? '';
    if (peerId.isEmpty || peerId == _myId) return;
    _friends.add(peerId);
    _friendRequests.removeWhere((r) => r['requestId'] == request['requestId']);
    await _persistFriends(); await _persistFriendRequests();
    try { if (LocalNetworkService.instance.isRunning) {
      await LocalNetworkService.instance.broadcastMessage(jsonEncode({'type':'friend_request_response','requestId':request['requestId'],'recipientId':peerId,'senderId':_myId,'senderName':widget.userName,'accepted':true}));
    }} catch (_) {}
    if (mounted) setState(() {});
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم قبول الطلب وحفظ الصداقة على هذا الجهاز.')));
  }

  Future<void> _rejectFriendRequest(Map<String, dynamic> request) async {
    final peerId = request['senderId']?.toString() ?? '';
    _friendRequests.removeWhere((r) => r['requestId'] == request['requestId']);
    await _persistFriendRequests();
    try { if (LocalNetworkService.instance.isRunning && peerId.isNotEmpty) {
      await LocalNetworkService.instance.broadcastMessage(jsonEncode({'type':'friend_request_response','requestId':request['requestId'],'recipientId':peerId,'senderId':_myId,'senderName':widget.userName,'accepted':false}));
    }} catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _showNotifications() async {
    await showModalBottomSheet<void>(context: context, showDragHandle: true, isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final requests = List<Map<String, dynamic>>.from(_friendRequests);
        return SafeArea(child: SizedBox(height: MediaQuery.of(ctx).size.height * .65, child: Column(children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('الإشعارات وطلبات الصداقة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          Expanded(child: requests.isEmpty ? const Center(child: Text('لا توجد طلبات صداقة جديدة')) : ListView(children: requests.map((r) => ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_add_alt_1)), title: Text('طلب صداقة من ${r['senderName'] ?? 'مستخدم'}'), subtitle: Text(_time(r['createdAt'])),
            trailing: Wrap(spacing: 0, children: [IconButton(tooltip:'قبول', onPressed: () async { await _acceptFriendRequest(r); setSheet(() {}); }, icon: const Icon(Icons.check_circle_outline, color: Colors.green)), IconButton(tooltip:'رفض', onPressed: () async { await _rejectFriendRequest(r); setSheet(() {}); }, icon: const Icon(Icons.close))]),
          )).toList())),
        ])));
      }));
  }

  Future<void> _onLanEvent(dynamic event) async {
    if (event.type != 'message' || event.message == null) return;
    try {
      final packet = jsonDecode(event.message!);
      if (packet is! Map) return;
      final packetType = packet['type']?.toString();
      final prefs = await SharedPreferences.getInstance();
      _myId = prefs.getString('wasl_user_id') ?? 'blousab-user';
      if (packetType == 'friend_request' && packet['recipientId']?.toString() == _myId) {
        final senderId = packet['senderId']?.toString() ?? '';
        if (senderId.isEmpty || senderId == _myId || _friends.contains(senderId)) return;
        final requestId = packet['requestId']?.toString() ?? '${senderId}_${packet['createdAt']}';
        // A sender can be discovered over more than one transport or replay a request.
        // Keep only one pending request per stable user ID.
        if (!_friendRequests.any((r) => r['senderId']?.toString() == senderId)) {
          _friendRequests.add({'requestId':requestId,'senderId':senderId,'senderName':packet['senderName']?.toString() ?? 'مستخدم','createdAt':packet['createdAt'] ?? DateTime.now().millisecondsSinceEpoch});
          await _persistFriendRequests(); if (mounted) setState(() {});
        }
        return;
      }
      if (packetType == 'friend_request_response' && packet['recipientId']?.toString() == _myId) {
        final peerId = packet['senderId']?.toString() ?? '';
        if (peerId.isNotEmpty && peerId != _myId && packet['accepted'] == true) {
          _friends.add(peerId); await _persistFriends();
          if (mounted) { setState(() {}); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('وافق ${packet['senderName'] ?? 'المستخدم'} على طلب الصداقة. تم حفظ الصداقة.'))); }
        } else if (mounted && peerId.isNotEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم رفض طلب الصداقة.'))); }
        return;
      }
      if (packetType == 'public_feed_sync_request') {
        for (final savedPost in List<Map<String, dynamic>>.from(_posts)) {
          try { await _broadcastPost(savedPost); } catch (_) {}
        }
        return;
      }
      if (packetType == 'public_feed_update') {
        final postId = packet['postId']?.toString() ?? '';
        final index = _posts.indexWhere((p) => p['id']?.toString() == postId);
        if (index < 0) return;
        final updated = Map<String, dynamic>.from(_posts[index]);
        final packetUpdatedAt = (packet['updatedAt'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
        final currentUpdatedAt = (updated['updatedAt'] as num?)?.toInt() ?? 0;
        if (packetUpdatedAt < currentUpdatedAt) return;
        updated['likes'] = List<String>.from(packet['likes'] as List? ?? const []);
        updated['comments'] = List<Map<String, dynamic>>.from(
          (packet['comments'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)),
        );
        updated['updatedAt'] = packetUpdatedAt;
        setState(() { _posts[index] = updated; _sortPosts(_posts); });
        await _save();
        return;
      }
      if (packetType != 'public_feed_post') return;
      final post = Map<String, dynamic>.from(packet['post'] as Map);
      if (post['authorId']?.toString() == _myId) return;
      final duplicateIndex = _posts.indexWhere((p) => p['id']?.toString() == post['id']?.toString());
      if (duplicateIndex >= 0) {
        // A peer may be replaying an existing post during sync; merge its latest
        // reactions/comments instead of silently ignoring the refreshed copy.
        final merged = Map<String, dynamic>.from(_posts[duplicateIndex]);
        merged['likes'] = List<String>.from(post['likes'] as List? ?? merged['likes'] as List? ?? const []);
        merged['comments'] = List<Map<String, dynamic>>.from(
          (post['comments'] as List? ?? merged['comments'] as List? ?? const [])
              .map((e) => Map<String, dynamic>.from(e as Map)),
        );
        final incomingUpdated = (post['updatedAt'] as num?)?.toInt() ?? 0;
        final currentUpdated = (merged['updatedAt'] as num?)?.toInt() ?? 0;
        if (incomingUpdated >= currentUpdated) merged['updatedAt'] = incomingUpdated;
        if (mounted) setState(() { _posts[duplicateIndex] = merged; _sortPosts(_posts); });
        await _save();
        return;
      }
      final profileData = post['profilePhotoBase64']?.toString();
      if (profileData != null && profileData.isNotEmpty) {
        try {
          final dir = await _feedDir();
          final photoFile = File('${dir.path}/profile_${post['authorId']}.jpg');
          await photoFile.writeAsBytes(base64Decode(profileData), flush: true);
          post['profilePhotoPath'] = photoFile.path;
        } catch (_) {}
        post.remove('profilePhotoBase64');
      }
      final data = post['mediaBase64']?.toString();
      if (data != null && data.isNotEmpty) {
        final bytes = base64Decode(data);
        final dir = await _feedDir();
        final ext = post['mediaType'] == 'video' ? 'mp4' : 'jpg';
        final file = File('${dir.path}/received_${post['id']}.$ext');
        await file.writeAsBytes(bytes, flush: true);
        post['mediaPath'] = file.path;
        post.remove('mediaBase64');
      }
      if (post['mediaPath'] == null && post['mediaType'] != 'text') return;
      if (!mounted) return;
      setState(() { _posts.add(post); _sortPosts(_posts); });
      await _save();
    } catch (_) { /* Ignore malformed or oversized/incomplete peer packets. */ }
  }

  Future<void> _createPost() async {
    final kind = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.photo_outlined), title: const Text('نشر صورة'), onTap: () => Navigator.pop(ctx, 'image')),
      ListTile(leading: const Icon(Icons.video_library_outlined), title: const Text('نشر فيديو'), onTap: () => Navigator.pop(ctx, 'video')),
      ListTile(leading: const Icon(Icons.notes_outlined), title: const Text('نشر نص فقط'), onTap: () => Navigator.pop(ctx, 'text')),
      const SizedBox(height: 8),
    ])));
    if (kind == null || !mounted || _busy) return;
    setState(() => _busy = true);
    String? mediaPath;
    try {
      if (kind == 'image') {
        final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 68, maxWidth: 1280, maxHeight: 1280);
        if (picked == null) return;
        final dir = await _feedDir(); mediaPath = '${dir.path}/post_${DateTime.now().microsecondsSinceEpoch}.jpg';
        await File(picked.path).copy(mediaPath);
      } else if (kind == 'video') {
        final picked = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60));
        if (picked == null) return;
        final compressed = await VideoCompress.compressVideo(picked.path, quality: VideoQuality.LowQuality, deleteOrigin: false, includeAudio: true);
        final file = compressed?.file ?? File(picked.path);
        final dir = await _feedDir(); mediaPath = '${dir.path}/post_${DateTime.now().microsecondsSinceEpoch}.mp4';
        await file.copy(mediaPath);
      }
      if (!mounted) return;
      final textController = TextEditingController();
      final tagsController = TextEditingController();
      final content = await showDialog<Map<String,String>?>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('منشور جديد'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (mediaPath != null) Container(width: double.infinity, padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)), child: Row(children: [Icon(kind == 'video' ? Icons.play_circle_outline : Icons.image_outlined), const SizedBox(width: 8), Expanded(child: Text(kind == 'video' ? 'فيديو مضغوط' : 'صورة مضغوطة'))])),
          TextField(controller: textController, maxLines: 4, maxLength: 1200, decoration: const InputDecoration(labelText: 'ماذا تريد أن تنشر؟', border: OutlineInputBorder())),
          const SizedBox(height: 10), TextField(controller: tagsController, decoration: const InputDecoration(labelText: 'هاشتاجات (مثال #بلوساب #أصدقاء)', border: OutlineInputBorder())),
          const SizedBox(height: 8), const Text('المنشور دائم على هذا الجهاز، ويُشارك مع الأجهزة المكتشفة على الشبكة المحلية عند توفر الاتصال.', style: TextStyle(fontSize: 12)),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () { if (kind == 'text' && textController.text.trim().isEmpty) return; Navigator.pop(ctx, {'text':textController.text.trim(),'tags':tagsController.text.trim()}); }, child: const Text('نشر'))],
      ));
      textController.dispose(); tagsController.dispose();
      if (content == null) return;
      final prefs = await SharedPreferences.getInstance();
      _myId = prefs.getString('wasl_user_id') ?? 'blousab-user';
      final post = <String,dynamic>{
        'id': '${_myId}_${DateTime.now().microsecondsSinceEpoch}', 'authorId': _myId,
        'authorName': widget.userName.isEmpty ? 'مستخدم بلوساب' : widget.userName,
        'profilePhotoPath': widget.profilePhotoPath, 'mediaType': kind, 'mediaPath': mediaPath,
        'text': content['text'] ?? '', 'hashtags': content['tags'] ?? '',
        'createdAt': DateTime.now().millisecondsSinceEpoch, 'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'likes': <String>[], 'comments': <Map<String,dynamic>>[],
      };
      setState(() => _posts.insert(0, post));
      await _save();
      try {
        if (LocalNetworkService.instance.isRunning) {
          await _broadcastPost(post);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('نُشر المنشور، وأُرسل إلى الأجهزة المكتشفة على الشبكة المحلية.')));
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('حُفظ المنشور على جهازك. فعّل اتصال الشبكة المحلية لمشاركته مع الأجهزة القريبة.')));
        }
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('حُفظ المنشور على جهازك، لكن تعذّر إرساله للأجهزة القريبة حاليًا.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تجهيز المنشور: $e')));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _toggleLike(Map<String,dynamic> post) async {
    final likes = List<String>.from(post['likes'] as List? ?? const []);
    if (likes.contains(_myId)) { likes.remove(_myId); } else { likes.add(_myId); }
    setState(() { post['likes'] = likes; post['updatedAt'] = DateTime.now().millisecondsSinceEpoch; }); await _save(); await _broadcastPostUpdate(post);
  }

  Future<void> _comments(Map<String,dynamic> post) async {
    final controller = TextEditingController();
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (ctx) => StatefulBuilder(builder: (ctx,setSheet) {
      final comments = List<Map<String,dynamic>>.from((post['comments'] as List? ?? const []).map((e) => Map<String,dynamic>.from(e as Map)));
      return Padding(padding: EdgeInsets.only(left: 16,right: 16,top: 8,bottom: MediaQuery.of(ctx).viewInsets.bottom+16), child: SizedBox(height: MediaQuery.of(ctx).size.height*0.55, child: Column(children: [
        const Text('التعليقات',style: TextStyle(fontSize: 18,fontWeight: FontWeight.bold)), const SizedBox(height: 12),
        Expanded(
          child: comments.isEmpty
              ? const Center(child: Text('لا توجد تعليقات بعد.'))
              : ListView(
                  children: comments.map((c) => ListTile(
                    dense: true,
                    leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                    title: Text(c['name']?.toString() ?? 'مستخدم'),
                    subtitle: Text(c['text']?.toString() ?? ''),
                  )).toList(),
                ),
        ),
        Row(children: [Expanded(child: TextField(controller: controller, maxLength: 500, decoration: const InputDecoration(hintText:'اكتب تعليقًا', counterText:'', border: OutlineInputBorder()))), const SizedBox(width:8), IconButton.filled(onPressed: () async { final text = controller.text.trim(); if (text.isEmpty) return; comments.add({'id':'${_myId}_${DateTime.now().microsecondsSinceEpoch}','name':widget.userName,'userId':_myId,'text':text,'createdAt':DateTime.now().millisecondsSinceEpoch}); post['comments'] = comments; post['updatedAt'] = DateTime.now().millisecondsSinceEpoch; controller.clear(); setSheet((){}); setState((){}); await _save(); await _broadcastPostUpdate(post); }, icon: const Icon(Icons.send))]),
      ])));
    }));
    controller.dispose();
  }

  Future<void> _requestChat(Map<String,dynamic> post) async {
    final authorId = post['authorId']?.toString() ?? '';
    if (authorId.isEmpty || authorId == _myId) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('هذا منشورك أنت.'))); return; }
    if (_friends.contains(authorId)) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversationId: 'peer_$authorId', title: post['authorName']?.toString() ?? 'صديق', currentUserId: _myId, currentUserName: widget.userName, initialPeerAddress: null, connectionAlreadyEstablished: false)));
      return;
    }
    final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('طلب صداقة قبل المحادثة'), content: Text('سيتم إرسال طلب صداقة إلى ${post['authorName'] ?? 'المستخدم'}. لن تُفتح المحادثة مباشرة.'), actions: [TextButton(onPressed: () => Navigator.pop(ctx,false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(ctx,true), child: const Text('إرسال الطلب'))]));
    if (accepted != true) return;
    final packet = jsonEncode({'type':'friend_request','requestId':'${_myId}_${DateTime.now().microsecondsSinceEpoch}','senderId':_myId,'senderName':widget.userName,'recipientId':authorId,'createdAt':DateTime.now().millisecondsSinceEpoch});
    try {
      if (!LocalNetworkService.instance.isRunning) throw StateError('no network');
      await LocalNetworkService.instance.broadcastMessage(packet);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أُرسل طلب الصداقة عبر الشبكة المحلية إن كان الجهاز متاحًا. لن تفتح المحادثة قبل الموافقة.')));
    } catch (_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر إرسال الطلب الآن. يجب أن يكون المستخدم متصلًا بالشبكة المحلية نفسها.'))); }
  }

  String _time(dynamic value) { final ms = (value as num?)?.toInt() ?? 0; final d = DateTime.fromMillisecondsSinceEpoch(ms); final delta = DateTime.now().difference(d); if (delta.inMinutes < 1) return 'الآن'; if (delta.inHours < 1) return 'منذ ${delta.inMinutes} د'; if (delta.inDays < 1) return 'منذ ${delta.inHours} س'; return '${d.day}/${d.month}/${d.year}'; }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الخلاصة العامة'), actions:[IconButton(tooltip:'ترتيب عشوائي / الأحدث',onPressed:_toggleOrder,icon:Icon(_randomOrder?Icons.shuffle:Icons.sort)),IconButton(tooltip:'الإشعارات وطلبات الصداقة',onPressed:_showNotifications,icon:Badge(isLabelVisible:_friendRequests.isNotEmpty,label:Text('${_friendRequests.length}'),child:const Icon(Icons.notifications_none))),IconButton(tooltip:'تحديث',onPressed:_refreshFeed,icon:const Icon(Icons.refresh))]),
    body: _loading ? const Center(child:CircularProgressIndicator()) : _loadError != null ? Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.cloud_off_outlined,size:52),const SizedBox(height:12),Text(_loadError!,textAlign:TextAlign.center),const SizedBox(height:12),FilledButton.icon(onPressed:_refreshFeed,icon:const Icon(Icons.refresh),label:const Text('إعادة المحاولة'))]))) : _posts.isEmpty ? Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.dynamic_feed_outlined,size:64,color:Theme.of(context).colorScheme.primary),const SizedBox(height:12),const Text('لا توجد منشورات بعد',style:TextStyle(fontSize:20,fontWeight:FontWeight.bold)),const SizedBox(height:8),const Text('انشر صورة أو فيديو أو نص. ستظهر المنشورات التي تصل من الأجهزة القريبة المتصلة بالشبكة المحلية.',textAlign:TextAlign.center)]))) : ListView.builder(controller:_scroll,padding:const EdgeInsets.only(bottom:90),itemCount:_posts.length,itemBuilder:(context,index){
      final post = _posts[index]; final author = post['authorName']?.toString() ?? 'مستخدم بلوساب'; final photo = post['profilePhotoPath']?.toString() ?? ''; final media = post['mediaPath']?.toString() ?? ''; final type = post['mediaType']?.toString() ?? 'text'; final likes = List<String>.from(post['likes'] as List? ?? const []); final comments = post['comments'] as List? ?? const []; final hashtags = post['hashtags']?.toString() ?? '';
      return Card(margin:const EdgeInsets.fromLTRB(10,8,10,4),clipBehavior:Clip.antiAlias, child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        ListTile(leading:CircleAvatar(backgroundImage:photo.isNotEmpty && File(photo).existsSync()?FileImage(File(photo)):null,child:photo.isEmpty || !File(photo).existsSync()?const Icon(Icons.person_outline):null),title:Text(author,style:const TextStyle(fontWeight:FontWeight.bold)),subtitle:Text(_time(post['createdAt'])),trailing:PopupMenuButton<String>(onSelected:(v) async { if(v=='delete' && post['authorId']==_myId){setState(()=>_posts.remove(post));await _save();} else if(v=='report'){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم تسجيل البلاغ محليًا.')));}},itemBuilder:(_)=>[if(post['authorId']==_myId) const PopupMenuItem(value:'delete',child:Text('حذف المنشور')),const PopupMenuItem(value:'report',child:Text('إبلاغ'))])),
        if(type=='image' && media.isNotEmpty) Container(width:double.infinity,constraints:const BoxConstraints(maxHeight:520),color:Theme.of(context).colorScheme.surfaceContainerHighest,child:Image.file(File(media),width:double.infinity,fit:BoxFit.contain,errorBuilder:(_,__,___)=>const SizedBox(height:180,child:Center(child:Icon(Icons.broken_image_outlined))))),
        if(type=='video' && media.isNotEmpty) _FeedVideo(path:media),
        if((post['text']?.toString() ?? '').isNotEmpty) Padding(padding:const EdgeInsets.fromLTRB(14,12,14,4),child:Text(post['text'].toString(),style:const TextStyle(fontSize:15))),
        if(hashtags.isNotEmpty) Padding(padding:const EdgeInsets.fromLTRB(14,4,14,8),child:Text(hashtags.split(RegExp(r'\s+')).map((tag)=>tag.startsWith('#')?tag:'#${tag}').join(' '),style:TextStyle(color:Theme.of(context).colorScheme.primary,fontWeight:FontWeight.w500))),
        Row(children:[IconButton(onPressed:()=>_toggleLike(post),icon:Icon(likes.contains(_myId)?Icons.favorite:Icons.favorite_border,color:likes.contains(_myId)?Colors.red:null)),Text('${likes.length}'),IconButton(onPressed:()=>_comments(post),icon:const Icon(Icons.mode_comment_outlined)),Text('${comments.length}'),const Spacer(),IconButton(tooltip:'طلب صداقة قبل المحادثة',onPressed:()=>_requestChat(post),icon:const Icon(Icons.chat_bubble_outline)),const SizedBox(width:8)]),
      ]));
    }),
    floatingActionButton:FloatingActionButton.extended(onPressed:_busy?null:_createPost,icon:_busy?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.add),label:Text(_busy?'جارٍ التجهيز':'إنشاء منشور')),
  );
}

class _FeedVideo extends StatefulWidget { final String path; const _FeedVideo({required this.path}); @override State<_FeedVideo> createState()=>_FeedVideoState(); }
class _FeedVideoState extends State<_FeedVideo> {
  late final VideoPlayerController _controller;
  bool _ready=false;
  @override void initState(){super.initState();_controller=VideoPlayerController.file(File(widget.path))..initialize().then((_){if(mounted)setState(()=>_ready=true);}).catchError((_){ });}
  @override void dispose(){_controller.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>_ready?GestureDetector(onTap:(){setState(()=>_controller.value.isPlaying?_controller.pause():_controller.play());},child:Stack(alignment:Alignment.center,children:[AspectRatio(aspectRatio:_controller.value.aspectRatio,child:VideoPlayer(_controller)),if(!_controller.value.isPlaying)const CircleAvatar(backgroundColor:Colors.black54,child:Icon(Icons.play_arrow,color:Colors.white))])):const SizedBox(height:200,child:Center(child:CircularProgressIndicator()));
}
