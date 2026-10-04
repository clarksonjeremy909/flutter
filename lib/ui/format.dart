String two(int n) => n.toString().padLeft(2, '0');

String clockTime(DateTime t) {
  final l = t.toLocal();
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

/// "12 sn önce", "3 dk önce", "2 sa önce".
String ago(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.isNegative || d.inSeconds < 1) return 'şimdi';
  if (d.inSeconds < 60) return '${d.inSeconds} sn önce';
  if (d.inMinutes < 60) return '${d.inMinutes} dk ${d.inSeconds % 60} sn önce';
  return '${d.inHours} sa ${d.inMinutes % 60} dk önce';
}

String inTime(DateTime t, DateTime now) {
  final d = t.difference(now);
  if (d.inSeconds <= 0) return 'şimdi';
  if (d.inSeconds < 60) return '${d.inSeconds} sn sonra';
  return '${d.inMinutes} dk ${d.inSeconds % 60} sn sonra';
}
