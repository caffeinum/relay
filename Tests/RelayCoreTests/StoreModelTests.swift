import Foundation
import Testing
@testable import RelayCore

@Test func migratesV1InPlace() throws {
    let path = try tempPath()
    do {
        let db = try Database(path: path)
        try db.exec("""
        CREATE TABLE users(id TEXT PRIMARY KEY, name TEXT NOT NULL, real_name TEXT NOT NULL, display_name TEXT NOT NULL,
            is_bot INTEGER NOT NULL, deleted INTEGER NOT NULL);
        CREATE TABLE convs(id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, user_id TEXT,
            last_read TEXT NOT NULL DEFAULT '0', seen TEXT NOT NULL DEFAULT '0', latest TEXT NOT NULL DEFAULT '0',
            synced TEXT, oldest TEXT, complete INTEGER NOT NULL DEFAULT 0, present INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE messages(id INTEGER PRIMARY KEY, channel TEXT NOT NULL, ts TEXT NOT NULL, thread_ts TEXT, user TEXT NOT NULL,
            text TEXT NOT NULL, subtype TEXT, reply_count INTEGER NOT NULL DEFAULT 0, latest_reply TEXT,
            edited INTEGER NOT NULL DEFAULT 0, reactions TEXT, UNIQUE(channel, ts));
        CREATE INDEX messages_thread ON messages(channel, thread_ts, ts);
        CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE VIRTUAL TABLE msg_fts USING fts5(text, tokenize = 'unicode61 remove_diacritics 2');
        INSERT INTO users VALUES('U2','mira','Mira Chen','',0,0);
        INSERT INTO convs(id,name,kind) VALUES('C1','eng','channel');
        INSERT INTO messages(channel,ts,user,text,edited) VALUES('C1','1.000000','U2','fixed',1);
        INSERT INTO messages(channel,ts,user,text) VALUES('C1','2.000000','B9','deploy done');
        INSERT INTO kv VALUES('ui.current','C1');
        PRAGMA user_version = 1;
        """)
    }
    let s = try Store(path: path)
    #expect(try s.db.scalar("PRAGMA user_version") == 2)
    let ms = try s.messages("C1")
    #expect(ms.map(\.text) == ["fixed", "deploy done"])
    #expect(ms[0].edited && ms[0].editedTS == "1.000000")
    #expect(ms[0].author == "Mira Chen")
    #expect(ms[1].botID == "B9" && ms[1].isBot)
    #expect(s.get("ui.current") == "C1")
    _ = try Store(path: path)
}

@Test func authorsResolveUserThenBotThenUsername() throws {
    let s = try seeded()
    var bot = slackMsg("103.000000", nil, "deployed", bot: "B1")
    bot.bot_profile = .init(id: "B1", name: "deploybot", icons: .init(image_48: "https://img/b.png"))
    var hook = slackMsg("104.000000", nil, "hook says hi", bot: "B2")
    hook.username = "webhook"
    try s.put(messages: [bot, hook, slackMsg("105.000000", nil, "ghost"), slackMsg("106.000000", "U404", "who")], channel: "C1")
    let ms = Dictionary(uniqueKeysWithValues: try s.messages("C1").map { ($0.ts, $0) })
    #expect(ms["102.000000"]?.author == "Mira Chen")
    #expect(ms["102.000000"]?.avatar == "https://img/m.png")
    #expect(ms["103.000000"]?.author == "deploybot")
    #expect(ms["103.000000"]?.avatar == "https://img/b.png")
    #expect(ms["103.000000"]?.isBot == true)
    #expect(ms["104.000000"]?.author == "webhook")
    #expect(ms["105.000000"]?.user == "")
    #expect(ms["105.000000"]?.author == "")
    #expect(ms["106.000000"]?.author == "U404")
    #expect(ms["101.000000"]?.isMine == true)
    #expect(ms["102.000000"]?.isMine == false)
}

@Test func messageFieldsFromSlack() throws {
    let s = try seeded()
    var m = slackMsg("110.000000", "U2", "see https://x.dev")
    m.edited = .init(ts: "111.000000")
    m.reply_count = 4
    m.reply_users = ["U2", "UME", "U3", "U4"]
    m.attachments = [.init(title: "X", text: "about x", service_name: "x.dev", title_link: "https://x.dev", color: "36a64f", thumb_url: "https://x.dev/t.png")]
    try s.put(messages: [m, slackMsg("112.000000", "U2", "<!subteam^S1> look"), slackMsg("113.000000", "U2", "<!here> standup"),
                         slackMsg("114.000000", "U2", "<@UME|aleks> ping"), slackMsg("115.000000", "U2", "<@U3> not me")], channel: "C1")
    try s.put(usergroups: [SlackUserGroup(id: "S1", handle: "eng", name: "Engineering", users: ["UME", "U2"])])
    let got = try #require(try s.message("C1", ts: "110.000000"))
    #expect(got.editedTS == "111.000000" && got.edited)
    #expect(got.replyCount == 4)
    #expect(got.replyUsers == ["U2", "UME", "U3"])
    #expect(got.unfurls == [Unfurl(title: "X", text: "about x", serviceName: "x.dev", url: "https://x.dev", color: "36a64f", thumb: "https://x.dev/t.png")])
    let mention = try s.messages("C1").filter(\.mentionsMe).map(\.ts)
    #expect(mention == ["112.000000", "113.000000", "114.000000"])
    #expect(try s.conversation("C1")?.mentions == 3)
}

@Test func systemMessagesAreFlagged() throws {
    let s = try seeded()
    var join = slackMsg("120.000000", "U2", "<@U2> has joined the channel")
    join.subtype = "channel_join"
    try s.put(messages: [join], channel: "C1")
    #expect(try s.message("C1", ts: "120.000000")?.isSystem == true)
    #expect(try s.message("C1", ts: "102.000000")?.isSystem == false)
}

@Test func conversationFields() throws {
    let s = try seeded()
    try s.put(users: [SlackUser(id: "UB", name: "helper", real_name: "Helper", is_bot: true, profile: .init())])
    var eng = channel("C1", "eng")
    eng.topic = .init(value: "Builds and bugs")
    var selfDM = SlackConversation(id: "D1", is_im: true, user: "UME")
    selfDM.last_read = "0"
    let botDM = SlackConversation(id: "D2", is_im: true, user: "UB")
    let group = SlackConversation(id: "G1", name: "mpdm-aleks--mira--zed-1", is_mpim: true)
    try s.put(conversations: [eng, selfDM, botDM, group], me: "UME")
    try s.saveDraft(Draft(channel: "C1", threadTS: "102.000000", text: "wip", selection: NSRange(location: 3, length: 0)))
    let cs = Dictionary(uniqueKeysWithValues: try s.conversations().map { ($0.id, $0) })
    #expect(cs["C1"]?.topic == "Builds and bugs")
    #expect(cs["C1"]?.hasDraft == true)
    #expect(cs["D1"]?.isSelf == true)
    #expect(cs["D2"]?.userIsBot == true && cs["D2"]?.isSelf == false)
    #expect(cs["G1"]?.name == "Mira Chen, zed")
    try s.put(members: ["UME", "U2"], channel: "G1")
    #expect(try s.conversation("G1")?.name == "Mira Chen")
}

@Test func dmMentionsCountEveryUnread() throws {
    let s = try seeded()
    try s.put(conversations: [channel("C1", "eng", lastRead: "100.000000"), SlackConversation(id: "D2", is_im: true, user: "U2", last_read: "0")], me: "UME")
    try s.put(messages: [slackMsg("1.000000", "U2", "hi"), slackMsg("2.000000", "U2", "there")], channel: "D2")
    let d = try #require(try s.conversation("D2"))
    #expect(d.unread == 2 && d.mentions == 2)
    #expect(d.name == "Mira Chen")
}

@Test func firstUnreadSkipsMineAndReplies() throws {
    let s = try seeded()
    try s.put(messages: [slackMsg("101.500000", "U2", "reply", thread: "100.000000")], channel: "C1")
    #expect(try s.firstUnread("C1") == "102.000000")
    try s.markSeen("C1", "102.000000")
    #expect(try s.firstUnread("C1") == nil)
    #expect(try s.markUnread("C1", from: "102.000000") == "101.999999")
    #expect(try s.firstUnread("C1") == "102.000000")
    #expect(try s.conversation("C1")?.unread == 1)
}

@Test func threadUnreadUsesThreadCursor() throws {
    let s = try seeded()
    try s.put(messages: [slackMsg("103.000000", "U2", "r1", thread: "100.000000"), slackMsg("104.000000", "UME", "r2", thread: "100.000000"),
                         slackMsg("105.000000", "U2", "r3", thread: "100.000000")], channel: "C1")
    #expect(try s.firstUnread("C1", thread: "100.000000") == "103.000000")
    try s.setUI(.threadRead("C1", "100.000000"), "103.000000")
    #expect(try s.firstUnread("C1", thread: "100.000000") == "105.000000")
}

@Test func reactionsApplyIdempotently() throws {
    let s = try seeded()
    #expect(try s.applyReaction(channel: "C1", ts: "102.000000", name: "eyes", user: "UME", add: true))
    #expect(try !s.applyReaction(channel: "C1", ts: "102.000000", name: "eyes", user: "UME", add: true))
    #expect(try s.applyReaction(channel: "C1", ts: "102.000000", name: "eyes", user: "U2", add: true))
    #expect(try s.message("C1", ts: "102.000000")?.reactions == [SlackReaction(name: "eyes", count: 2, users: ["UME", "U2"])])
    #expect(try s.applyReaction(channel: "C1", ts: "102.000000", name: "eyes", user: "UME", add: false))
    #expect(try s.applyReaction(channel: "C1", ts: "102.000000", name: "eyes", user: "U2", add: false))
    #expect(try s.message("C1", ts: "102.000000")?.reactions == [])
    #expect(try !s.applyReaction(channel: "C1", ts: "999.000000", name: "eyes", user: "U2", add: true))
}

@Test func olderPageAndSingleMessage() throws {
    let s = try seeded()
    #expect(try s.messages("C1", before: "102.000000", limit: 1).map(\.ts) == ["101.000000"])
    #expect(try s.message("C1", ts: "404.000000") == nil)
}

@Test func unreadCountsUseTheIndexes() throws {
    let s = try seeded()
    func plan(_ sql: String, _ args: [SQLBindable] = ["UME", "%x%"]) throws -> String {
        try s.db.query("EXPLAIN QUERY PLAN " + sql, args) { $0.text(3) }.joined(separator: "\n")
    }
    let unread = try plan("WITH c AS (SELECT *, '0' AS read FROM convs) SELECT (\(Store.unreadSQL)) FROM c", ["UME"])
    #expect(unread.contains("messages_top") || unread.contains("sqlite_autoindex_messages_1"), "\(unread)")
    #expect(!unread.contains("SCAN m"), "\(unread)")
    let mentions = try plan("WITH c AS (SELECT *, '0' AS read FROM convs) SELECT (\(Store.mentionSQL(1))) FROM c")
    #expect(mentions.contains("USING INDEX") || mentions.contains("USING COVERING INDEX"), "\(mentions)")
    #expect(!mentions.contains("SCAN m"), "\(mentions)")
}

@Test func peopleAreCachedAndInvalidated() throws {
    let s = try seeded()
    #expect(try s.people().map(\.handle) == ["aleks", "mira"])
    #expect(s.person("U2")?.label == "Mira Chen")
    try s.put(users: [SlackUser(id: "U2", name: "mira", real_name: "Mira Chen", profile: .init(display_name: "mira.c"))])
    #expect(s.person("U2")?.label == "mira.c")
    #expect(s.name(of: "U404") == "U404")
}

@Test func directoryTablesReadBack() throws {
    let s = try seeded()
    try s.put(bots: [SlackBot(id: "B1", name: "deploybot", user_id: "UB1", icons: .init(image_48: "https://b"))])
    #expect(s.bot("B1") == Bot(id: "B1", name: "deploybot", userID: "UB1", image48: "https://b"))
    try s.put(usergroups: [SlackUserGroup(id: "S1", handle: "eng", name: "Engineering", users: ["UME"]),
                           SlackUserGroup(id: "S2", handle: "ops", name: "Ops", users: ["U2"])])
    #expect(try s.usergroups().map(\.handle) == ["eng", "ops"])
    #expect(s.myGroups() == ["S1"])
    try s.put(emoji: ["party": "https://e/p.gif", "yay": "alias:party"], replacing: true)
    try s.removeEmoji(["yay"])
    #expect(try s.customEmoji() == ["party": "https://e/p.gif"])
    try s.put(members: ["UME", "U2"], channel: "C1")
    #expect(try s.members("C1") == ["UME", "U2"])
    #expect(try s.membersFetched("C1") != nil)
}

@Test func aPersonPostingThroughAnAppIsNotABot() throws {
    let s = try seeded()
    var m = SlackMessage(ts: "300.000000", user: "UME", text: "sent from relay")
    m.bot_id = "BAPP"
    try s.put(messages: [m], channel: "C1")
    #expect(try s.message("C1", ts: "300.000000")?.isBot == false)
}
