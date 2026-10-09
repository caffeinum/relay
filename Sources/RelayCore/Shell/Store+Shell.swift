import Foundation

/// The sidebar's top items: threads I'm in and messages that mention me,
/// straight from the cache.
extension Store {
    /// Parents I started or replied in, newest reply first (T5). `unread`
    /// is a reply after my local thread read cursor.
    public func threads(limit: Int = 50) throws -> [(message: Message, unread: Bool)] {
        guard let me else { return [] }
        let refs = try db.query("""
            SELECT m.channel, m.ts FROM messages m
            WHERE m.reply_count > 0 AND (m.thread_ts IS NULL OR m.thread_ts = m.ts)
              AND (m.user = ? OR EXISTS(SELECT 1 FROM messages r WHERE r.channel = m.channel AND r.thread_ts = m.ts AND r.user = ?))
            ORDER BY coalesce(m.latest_reply, m.ts) DESC LIMIT ?
            """, me, me, limit) { ($0.text(0), $0.text(1)) }
        return try refs.compactMap { c, ts in
            guard let m = try message(c, ts: ts) else { return nil }
            let read = try ui(UIKey<String>.threadRead(c, ts)) ?? ts
            return (m, m.latestReply.map { ListLayout.tsLess(read, $0) } ?? false)
        }
    }

    /// Messages from others that mention me, my groups or @here, newest first.
    public func mentionsOfMe(limit: Int = 50) throws -> [Message] {
        guard let me else { return [] }
        let patterns = mentionPatterns(me)
        let like = patterns.map { _ in "text LIKE ?" }.joined(separator: " OR ")
        let refs = try db.query("SELECT channel, ts FROM messages WHERE user != ? AND instr(text, '<') > 0 AND (\(like)) ORDER BY ts DESC LIMIT ?",
                                [me] + patterns + [limit]) { ($0.text(0), $0.text(1)) }
        return try refs.compactMap { try message($0.0, ts: $0.1) }
    }
}
