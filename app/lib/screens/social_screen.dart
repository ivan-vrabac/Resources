import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';
import 'dm_screen.dart';

/// Social: global chat (opens first), contacts and private messages — switched at the top.
class SocialScreen extends StatefulWidget {
  const SocialScreen({super.key});
  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen> {
  int _tab = 0;
  int _unreadDm = 0;

  @override
  void initState() {
    super.initState();
    _refreshUnread();
  }

  Future<void> _refreshUnread() async {
    final r = await GameApi.call('/api/v1/chat/dm/threads', context.read<PlayerProvider>().sid);
    if (mounted && r.ok) setState(() => _unreadDm = (r.data['unread'] as num? ?? 0).toInt());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              const ButtonSegment(value: 0, icon: Icon(Icons.forum_outlined, size: 16), label: Text('Chat')),
              const ButtonSegment(value: 1, icon: Icon(Icons.people_alt_outlined, size: 16), label: Text('Contacts')),
              ButtonSegment(value: 2, icon: Badge(isLabelVisible: _unreadDm > 0, label: Text('$_unreadDm'),
                  child: const Icon(Icons.mail_outline, size: 16)), label: const Text('Messages')),
            ],
            selected: {_tab},
            onSelectionChanged: (v) { setState(() => _tab = v.first); _refreshUnread(); },
          ),
        ),
        Expanded(
          child: IndexedStack(index: _tab, children: const [
            ChatScreen(embedded: true),
            ContactsScreen(),
            DmThreadsScreen(embedded: true),
          ]),
        ),
      ]),
    );
  }
}
