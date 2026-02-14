// lib/features/prs1/model/prs1_summary.dart

import 'prs1_session.dart';

class Prs1Summary {
  const Prs1Summary({
    required this.device,
    required this.sessions,
  });

  final Object device; // placeholder: wire to Prs1Device later
  final List<Prs1Session> sessions;
}
