// 微信聊天研究 1.1.0 — pkc 式微信内插件
// 注入微信进程(com.tencent.xin)，右下角悬浮球 → 全屏研究页面
// 会话列表 / 对话气泡 / 搜索 / 按天统计 / AI研究模式(选人+时间段→DeepSeek分析讨论)
// 实时只读微信沙盒 DB，AI 调用走 DeepSeek API(用户自配 key)
//
// arm64e 编译限制（全部遵守）：
//   - 不定义新 ObjC 类（objc_allocateClassPair 动态创建）
//   - 不用 %new（class_addMethod）
//   - 不用 block（dispatch_after_f + C 函数）
//   - @"..." 一律 BJCStr()
//   - objc_msgSend 一律走宏

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>

#define BJCStr(lit) [NSString stringWithUTF8String:lit]

typedef id (*BJMsgSend0)(id, SEL);
typedef void (*BJMsgSendV1)(id, SEL, id);
typedef void (*BJMsgSendV2)(id, SEL, BOOL, id);
typedef id (*BJMsgSend1)(id, SEL, id);
typedef id (*BJMsgSend2)(id, SEL, id, id);
#define BJ_MSG_SEND0(rcv, sel) ((BJMsgSend0)objc_msgSend)(rcv, sel)
#define BJ_MSG_SENDV1(rcv, sel, a) ((BJMsgSendV1)objc_msgSend)(rcv, sel, a)
#define BJ_MSG_SENDV2(rcv, sel, a, b) ((BJMsgSendV2)objc_msgSend)(rcv, sel, a, b)
#define BJ_MSG_SEND1(rcv, sel, a) ((BJMsgSend1)objc_msgSend)(rcv, sel, a)
#define BJ_MSG_SEND2(rcv, sel, a, b) ((BJMsgSend2)objc_msgSend)(rcv, sel, a, b)

static BOOL WXPageOpen = NO;
static id WXMsgHandlerObj = nil;
static id WXPageVC = nil;
static NSString *WXCurrentChatUsr = nil;
static id WXBall = nil;
static Class WXBallTargetCls = nil;
static id WXBallTarget = nil;
// AI 研究状态
static NSMutableArray *WXAIHistory = nil;   // AI 对话历史（含系统提示+聊天记录）
static NSString *WXAIKey = nil;             // DeepSeek API key（NSUserDefaults 缓存）

// 前置声明（定义在使用之后，C 需要先声明）
static NSString *WXAIExtractContent(NSString *html);
static NSString *WXCurrentChatUser(void);
static UIViewController *WXTopVC(void);

// ============ 文件日志（iOS 16 无 syslog 可抓，写沙盒文件） ============
static void WXLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:BJCStr("Documents/wxresearch.log")];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    NSData *line = [[msg stringByAppendingString:BJCStr("\n")] dataUsingEncoding:NSUTF8StringEncoding];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:line];
        [fh closeFile];
    } else {
        [line writeToFile:path atomically:YES];
    }
}

// ============ MD5（表名 = md5(userName) 小写） ============
static NSString *WXMD5(NSString *input) {
    const char *cStr = [input UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [out appendFormat:BJCStr("%02x"), digest[i]];
    return out;
}

// ============ JS 字符串转义（JSON 拼进 JS 源码必须转义，否则双层解码炸） ============
static NSString *WXJSEscape(NSString *s) {
    if (!s) return BJCStr("");
    NSMutableString *out = [NSMutableString string];
    NSUInteger len = [s length];
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '\\': [out appendString:BJCStr("\\\\")]; break;
            case '\'': [out appendString:BJCStr("\\'")]; break;
            case '\n': [out appendString:BJCStr("\\n")]; break;
            case '\r': [out appendString:BJCStr("\\r")]; break;
            case '\t': [out appendString:BJCStr("\\t")]; break;
            case 0x2028: [out appendString:BJCStr("\\u2028")]; break;
            case 0x2029: [out appendString:BJCStr("\\u2029")]; break;
            default: [out appendFormat:BJCStr("%C"), c]; break;
        }
    }
    return out;
}

// ============ 数据库定位：微信沙盒 Documents/<md5>/DB ============
static NSString *WXFindDBDir(void) {
    NSString *doc = [NSHomeDirectory() stringByAppendingPathComponent:BJCStr("Documents")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *subs = [fm contentsOfDirectoryAtPath:doc error:nil];
    for (NSString *sub in subs) {
        if ([sub length] == 32) { // md5 目录
            NSString *db = [doc stringByAppendingPathComponent:[sub stringByAppendingPathComponent:BJCStr("DB")]];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:db isDirectory:&isDir] && isDir) {
                // 必须是消息库所在目录（有 message_*.sqlite），跳过 0000... 空目录
                NSArray *files = [fm contentsOfDirectoryAtPath:db error:nil];
                for (NSString *f in files)
                    if ([f hasPrefix:BJCStr("message_")] && [f hasSuffix:BJCStr(".sqlite")])
                        return db;
            }
        }
    }
    return nil;
}

static NSArray *WXFindMsgDBs(void) {
    NSString *dir = WXFindDBDir();
    if (!dir) return @[];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *dbs = [NSMutableArray array];
    for (NSString *f in files)
        if ([f hasPrefix:BJCStr("message_")] && [f hasSuffix:BJCStr(".sqlite")])
            [dbs addObject:[dir stringByAppendingPathComponent:f]];
    return dbs;
}

// ============ 字符串清洗：替换未配对 surrogate（损坏 emoji 的 UTF-8 解码产物，会炸 JSON 序列化） ============
static NSString *WXCleanSurrogates(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || ![s length]) return s;
    NSUInteger len = [s length];
    BOOL dirty = NO;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        if (CFStringIsSurrogateHighCharacter(c)) {
            if (i + 1 < len && CFStringIsSurrogateLowCharacter([s characterAtIndex:i + 1])) { i++; }
            else { dirty = YES; break; }
        } else if (CFStringIsSurrogateLowCharacter(c)) { dirty = YES; break; }
    }
    if (!dirty) return s;
    NSMutableString *ms = [NSMutableString stringWithCapacity:len];
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        if (CFStringIsSurrogateHighCharacter(c) && i + 1 < len && CFStringIsSurrogateLowCharacter([s characterAtIndex:i + 1])) {
            [ms appendFormat:BJCStr("%C%C"), c, [s characterAtIndex:i + 1]];
            i++;
        } else if (CFStringIsSurrogateHighCharacter(c) || CFStringIsSurrogateLowCharacter(c)) {
            [ms appendString:BJCStr("\uFFFD")]; // 未配对 → 替换字符
        } else {
            [ms appendFormat:BJCStr("%C"), c];
        }
    }
    return ms;
}

// 递归清洗 JSON 数据（防任何路径漏网的坏字符串/二进制）
static id WXJSONSafe(id obj) {
    if ([obj isKindOfClass:[NSString class]]) return WXCleanSurrogates(obj);
    if ([obj isKindOfClass:[NSData class]]) {
        // BLOB（如语音消息 Message 字段）不能进 JSON → 转描述文本
        return [NSString stringWithFormat:BJCStr("[二进制数据 %lu字节]"), (unsigned long)[(NSData *)obj length]];
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id o in obj) [a addObject:WXJSONSafe(o)];
        return a;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        for (id k in obj) d[WXJSONSafe(k)] = WXJSONSafe(obj[k]);
        return d;
    }
    return obj;
}

#define WXZHIPUKEY "REPLACE_ZHIPU_KEY"
#define WXSTEPFUNKEY "REPLACE_STEPFUN_KEY"
#define WXDEEPSEEKKEY "REPLACE_DEEPSEEK_KEY"

// ============ sqlite 只读查询 → NSArray/NSDictionary ============
static sqlite3 *WXOpenRO(NSString *path) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([path UTF8String], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK)
        return db;
    if (db) sqlite3_close(db);
    return NULL;
}

static NSArray *WXQuery(NSString *dbPath, NSString *sql, int limit) {
    sqlite3 *db = WXOpenRO(dbPath);
    if (!db) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
        int count = 0;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            int ncol = sqlite3_column_count(stmt);
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            for (int i = 0; i < ncol; i++) {
                const char *name = sqlite3_column_name(stmt, i);
                NSString *k = nil;
                if (name) k = [NSString stringWithUTF8String:name];
                if (!k) k = [NSString stringWithFormat:BJCStr("c%d"), i];
                int type = sqlite3_column_type(stmt, i);
                if (type == SQLITE_INTEGER)
                    row[k] = @(sqlite3_column_int64(stmt, i));
                else if (type == SQLITE_FLOAT)
                    row[k] = @(sqlite3_column_double(stmt, i));
                else if (type == SQLITE_NULL)
                    row[k] = @"";
                else if (type == SQLITE_BLOB) {
                    // BLOB 列保留原始字节（NSData），供 protobuf 解析；不能走 column_text 转字符串
                    const void *blob = sqlite3_column_blob(stmt, i);
                    int blen = sqlite3_column_bytes(stmt, i);
                    row[k] = blob ? [NSData dataWithBytes:blob length:(NSUInteger)blen] : [NSData data];
                }
                else {
                    const char *txt = (const char *)sqlite3_column_text(stmt, i);
                    if (txt) {
                        NSString *s = [NSString stringWithUTF8String:txt];
                        if (!s) {
                            // 非法 UTF-8（语音/位置消息的二进制 blob）：Latin1 兜底防崩溃
                            s = [[NSString alloc] initWithBytes:txt length:strlen(txt) encoding:NSISOLatin1StringEncoding];
                        }
                        row[k] = WXCleanSurrogates(s ?: @"");
                    } else {
                        row[k] = @"";
                    }
                }
            }
            [rows addObject:row];
            if (limit > 0 && ++count >= limit) break;
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return rows;
}

// ============ protobuf 提取 field 1 字符串（备注 dbContactRemark 格式：0A <len> <utf8>） ============
static NSString *WXProtoField1Str(NSData *data) {
    // 防御：只接受 NSData（BLOB 列），防止类型错乱崩溃
    if (![data isKindOfClass:[NSData class]] || [data length] < 3) return nil;
    const unsigned char *b = [data bytes];
    NSUInteger len = [data length];
    NSUInteger i = 0;
    while (i < len) {
        unsigned char tag = b[i++];
        if ((tag & 0x07) != 2) continue; // 非 length-delimited 字段跳过
        uint64_t slen = 0; int shift = 0;
        while (i < len && (b[i] & 0x80)) {
            slen |= ((uint64_t)(b[i] & 0x7F)) << shift; shift += 7; i++;
        }
        if (i >= len) break;
        slen |= ((uint64_t)b[i]) << shift; i++;
        if (i + slen > len) break;
        if ((tag >> 3) == 1) { // field 1
            NSString *s = [[NSString alloc] initWithBytes:(b + i) length:(NSUInteger)slen encoding:NSUTF8StringEncoding];
            return WXCleanSurrogates(s ?: @"");
        }
        i += (NSUInteger)slen;
    }
    return nil;
}

// ============ 联系人：userName → 显示名（备注 protobuf 优先 → 微信号兜底） ============
// 新版微信：联系人库在 WCDB_Contact.sqlite（MM.sqlite 的 Friend 表是空的）
static NSString *WXContactName(NSString *usrName) {
    if (!usrName || ![usrName length]) return BJCStr("?");
    NSString *dbDir = WXFindDBDir();
    if (!dbDir) return usrName;
    NSString *wc = [dbDir stringByAppendingPathComponent:BJCStr("WCDB_Contact.sqlite")];
    NSString *esc = [usrName stringByReplacingOccurrencesOfString:BJCStr("'") withString:BJCStr("''")];
    NSArray *r = WXQuery(wc, [NSString stringWithFormat:BJCStr("SELECT dbContactRemark FROM Friend WHERE userName='%@'"), esc], 1);
    if ([r count]) {
        NSString *rm = WXProtoField1Str(r[0][BJCStr("dbContactRemark")]);
        if ([rm length]) return rm;
    }
    if ([usrName hasSuffix:BJCStr("@chatroom")]) {
        // 群名本地无持久化，显示群号前缀便于区分
        if ([usrName length] > 12) return [NSString stringWithFormat:BJCStr("群[%@…]"), [usrName substringToIndex:8]];
        return usrName;
    }
    return usrName;
}

// ============ 会话列表 ============
// 遍历所有 message_*.sqlite 的 Chat_<md5> 表（排除 ChatExt2_ 扩展表）→ md5 反查 UsrName → 显示名
// 轻量化：只查 MAX(CreateTime)（不查 COUNT），按最近时间倒序取前 300 个
static NSArray *WXListSessions(void) {
    NSMutableArray *sessions = [NSMutableArray array];
    NSString *dbDir = WXFindDBDir();
    if (!dbDir) return sessions;
    NSString *mm = [dbDir stringByAppendingPathComponent:BJCStr("MM.sqlite")];
    // 一次性查全部联系人：md5→userName 映射 + 显示名（备注优先）缓存
    NSMutableDictionary *md5ToUser = [NSMutableDictionary dictionary];
    NSMutableDictionary *nameByUser = [NSMutableDictionary dictionary];
    NSString *wc = [dbDir stringByAppendingPathComponent:BJCStr("WCDB_Contact.sqlite")];
    NSArray *friends = WXQuery(wc, BJCStr("SELECT userName, dbContactRemark FROM Friend"), 0);
    for (NSDictionary *f in friends) {
        NSString *u = f[BJCStr("userName")];
        if (![u length]) continue;
        md5ToUser[[WXMD5(u) lowercaseString]] = u;
        NSString *rm = WXProtoField1Str(f[BJCStr("dbContactRemark")]);
        if ([rm length]) nameByUser[u] = rm;
    }
    NSArray *dbs = WXFindMsgDBs();
    for (NSString *db in dbs) {
        // substr(name,1,5)='Chat_' 精确匹配，排除 ChatExt2_ 等扩展表
        NSArray *tabs = WXQuery(db, BJCStr("SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,5)='Chat_'"), 0);
        for (NSDictionary *t in tabs) {
            NSString *tab = t[BJCStr("name")];
            NSString *key = [tab substringFromIndex:5]; // 去掉 Chat_
            NSString *usrName = md5ToUser[key];
            NSString *display = usrName ? (nameByUser[usrName] ?: (([usrName hasSuffix:BJCStr("@chatroom")] && [usrName length] > 12) ? [NSString stringWithFormat:BJCStr("群[%@…]"), [usrName substringToIndex:8]] : usrName)) : ([key length] >= 8 ? [NSString stringWithFormat:BJCStr("%@…"), [key substringToIndex:8]] : key);
            NSArray *info = WXQuery(db, [NSString stringWithFormat:BJCStr("SELECT CreateTime AS last FROM %@ ORDER BY MesLocalID DESC LIMIT 1"), tab], 1);
            long long last = 0;
            if ([info count]) {
                last = [info[0][BJCStr("last")] longLongValue];
            }
            NSMutableDictionary *s = [NSMutableDictionary dictionary];
            s[BJCStr("table")] = tab;
            s[BJCStr("db")] = db;
            s[BJCStr("userName")] = usrName ?: @"";
            s[BJCStr("name")] = display;
            s[BJCStr("lastTime")] = @(last);
            [sessions addObject:s];
        }
    }
    // 按最后时间倒序，取最近 300 个（列表轻量）
    [sessions sortUsingComparator:^NSComparisonResult(id a, id b) {
        long long ta = [a[BJCStr("lastTime")] longLongValue];
        long long tb = [b[BJCStr("lastTime")] longLongValue];
        return ta > tb ? NSOrderedAscending : (ta < tb ? NSOrderedDescending : NSOrderedSame);
    }];
    if ([sessions count] > 300) {
        sessions = [NSMutableArray arrayWithArray:[sessions subarrayWithRange:NSMakeRange(0, 300)]];
    }
    return sessions;
}

// ============ 搜索会话：按备注 / 昵称 / 微信号 ============
static NSArray *WXSearchSessions(NSString *kw) {
    if (![kw length]) return @[];
    NSString *dbDir = WXFindDBDir();
    if (!dbDir) return @[];
    NSString *mm = [dbDir stringByAppendingPathComponent:BJCStr("MM.sqlite")];
    // LIKE 通配符转义
    NSString *esc = [kw stringByReplacingOccurrencesOfString:BJCStr("%") withString:BJCStr("\\%")];
    esc = [esc stringByReplacingOccurrencesOfString:BJCStr("_") withString:BJCStr("\\_")];
    NSString *like = [NSString stringWithFormat:BJCStr("%%%@%%"), esc];
    // 收集匹配的 userName → 显示名（备注优先，来自 WCDB_Contact.sqlite）
    NSMutableDictionary *nameByUser = [NSMutableDictionary dictionary];
    NSString *wc = [dbDir stringByAppendingPathComponent:BJCStr("WCDB_Contact.sqlite")];
    NSArray *r1 = WXQuery(wc, [NSString stringWithFormat:BJCStr(
        "SELECT userName FROM Friend WHERE dbContactRemark LIKE '%@' ESCAPE '\\' OR userName LIKE '%@' ESCAPE '\\' OR CAST(dbContactProfile AS TEXT) LIKE '%@' ESCAPE '\\' LIMIT 80"), like, like, like], 0);
    for (NSDictionary *r in r1) {
        NSString *u = r[BJCStr("userName")];
        if ([u length]) nameByUser[u] = WXContactName(u);
    }
    if (![nameByUser count]) return @[];
    // 反查这些用户在哪个 DB 有 Chat_ 表
    NSMutableArray *out = [NSMutableArray array];
    NSArray *dbs = WXFindMsgDBs();
    for (NSString *u in nameByUser) {
        NSString *md5 = [WXMD5(u) lowercaseString];
        for (NSString *db in dbs) {
            NSArray *tabs = WXQuery(db, [NSString stringWithFormat:BJCStr(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='Chat_%@'"), md5], 1);
            if ([tabs count]) {
                NSArray *info = WXQuery(db, [NSString stringWithFormat:BJCStr(
                    "SELECT CreateTime AS last FROM Chat_%@ ORDER BY MesLocalID DESC LIMIT 1"), md5], 1);
                long long last = 0;
                if ([info count]) last = [info[0][BJCStr("last")] longLongValue];
                NSMutableDictionary *s = [NSMutableDictionary dictionary];
                s[BJCStr("table")] = [tabs[0][BJCStr("name")] length] ? tabs[0][BJCStr("name")] : [NSString stringWithFormat:BJCStr("Chat_%@"), md5];
                s[BJCStr("db")] = db;
                s[BJCStr("userName")] = u;
                s[BJCStr("name")] = nameByUser[u] ?: u;
                s[BJCStr("lastTime")] = @(last);
                [out addObject:s];
                break;
            }
        }
    }
    return out;
}

// ============ 消息查询（分页，最新在前，返回给前端反转为正序） ============
static NSArray *WXFetchMessages(NSString *db, NSString *table, int offset, int limit) {
    NSString *sql = [NSString stringWithFormat:BJCStr(
        "SELECT MesLocalID, CreateTime, Type, Message, Des FROM %@ ORDER BY MesLocalID DESC LIMIT %d OFFSET %d"),
        table, limit, offset];
    NSArray *rows = WXQuery(db, sql, 0);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in [rows reverseObjectEnumerator]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:r];
        // isMe 判断：Des 是 INTEGER，0=自己 1=他人（不能当字符串用 [length]，会 unrecognized selector 崩溃）
        long long desVal = [m[BJCStr("Des")] longLongValue];
        m[BJCStr("isMe")] = @(desVal == 0);
        [out addObject:m];
    }
    return out;
}

// ============ 搜索 ============
static NSArray *WXSearchMessages(NSString *db, NSString *table, NSString *kw, int limit) {
    NSString *sql = [NSString stringWithFormat:BJCStr(
        "SELECT MesLocalID, CreateTime, Type, Message FROM %@ WHERE Message LIKE '%%%@%%' ORDER BY MesLocalID DESC LIMIT %d"),
        table, kw, limit];
    return WXQuery(db, sql, 0);
}

// ============ 时间段 + 分页拉消息（聊天记录时间过滤） ============
// 倒序取最新（与 WXFetchMessages 一致），offset 从最新往前翻
static NSArray *WXFetchMessagesRangeDB(NSString *db, NSString *table, long long startTs, long long endTs, int offset, int limit) {
    NSString *sql = [NSString stringWithFormat:BJCStr(
        "SELECT MesLocalID, CreateTime, Type, Message, Des FROM %@ "
        "WHERE CreateTime>=%lld AND CreateTime<=%lld ORDER BY MesLocalID DESC LIMIT %d OFFSET %d"),
        table, startTs, endTs, limit, offset];
    NSArray *rows = WXQuery(db, sql, 0);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in [rows reverseObjectEnumerator]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:r];
        long long desVal = [m[BJCStr("Des")] longLongValue];
        m[BJCStr("isMe")] = @(desVal == 0);
        [out addObject:m];
    }
    return out;
}

// ============ 按时间段提取消息（正序，用于 AI 研究） ============
static NSArray *WXFetchMessagesRange(NSString *db, NSString *table, long long startTs, long long endTs, int limit) {
    NSString *sql;
    if (startTs > 0 && endTs > 0) {
        // 用主键 MesLocalID 排序（CreateTime 无索引，ORDER BY CreateTime 会全表扫描超慢）
        sql = [NSString stringWithFormat:BJCStr(
            "SELECT MesLocalID, CreateTime, Type, Message, Des FROM %@ WHERE CreateTime>=%lld AND CreateTime<=%lld ORDER BY MesLocalID ASC LIMIT %d"),
            table, startTs, endTs, limit];
    } else {
        sql = [NSString stringWithFormat:BJCStr(
            "SELECT MesLocalID, CreateTime, Type, Message, Des FROM %@ ORDER BY MesLocalID DESC LIMIT %d"),
            table, limit];
    }
    NSArray *rows = WXQuery(db, sql, 0);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in rows) {
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:r];
        // isMe：Des 是 INTEGER（0=自己 1=他人）
        long long desVal = [m[BJCStr("Des")] longLongValue];
        m[BJCStr("isMe")] = @(desVal == 0);
        [out addObject:m];
    }
    return out;
}

// ============ 消息 → 文本（AI 研究用） ============
static NSString *WXMessagesToText(NSArray *msgs, NSString *selfName, NSString *otherName) {
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *m in msgs) {
        long long ts = [m[BJCStr("CreateTime")] longLongValue];
        int type = (int)[m[BJCStr("Type")] longLongValue];
        NSString *msg = m[BJCStr("Message")];
        // 类型安全：Message 列可能混存数字/其他类型（SQLite 动态类型），统一转字符串防 unrecognized selector
        if (![msg isKindOfClass:[NSString class]]) {
            msg = msg ? [msg description] : @"";
        }
        NSString *who = [m[BJCStr("isMe")] boolValue] ? selfName : otherName;
        // 群消息 sender 前缀 wxid_xxx: 去掉
        NSRange colon = [msg rangeOfString:BJCStr(":")];
        if (![m[BJCStr("isMe")] boolValue] && colon.location != NSNotFound &&
            [msg hasPrefix:BJCStr("wxid_")]) {
            msg = [msg substringFromIndex:colon.location + 1];
        }
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:BJCStr("MM-dd HH:mm")];
        NSString *tsStr = [fmt stringFromDate:d];
        NSString *body;
        if (type == 1 || type == 10000) body = msg;
        else if (type == 3) body = BJCStr("[图片]");
        else if (type == 34) body = BJCStr("[语音]");
        else if (type == 43) body = BJCStr("[视频]");
        else if (type == 47) body = BJCStr("[表情]");
        else if (type == 49) {
            NSRange t = [msg rangeOfString:BJCStr("<title>")];
            NSRange te = [msg rangeOfString:BJCStr("</title>")];
            if (t.location != NSNotFound && te.location != NSNotFound && te.location > t.location) {
                NSString *tt = [msg substringWithRange:NSMakeRange(t.location + 7, te.location - t.location - 7)];
                body = [NSString stringWithFormat:BJCStr("[链接] %@"), tt];
            } else body = BJCStr("[链接]");
        }
        else if (type == 50) body = BJCStr("[语音通话]");
        else body = [NSString stringWithFormat:BJCStr("[消息类型%d]"), type];
        [text appendFormat:BJCStr("%@ %@: %@\n"), tsStr, who, body];
    }
    return text;
}

// ============ OpenAI 兼容 API 调用（同步请求，避免 block） ============
// 通用：POST baseURL + model + messages，返回 JSON 字符串（error 时返回 nil）
static NSString *WXAIRequestURL(NSString *baseURL, NSString *apiKey, NSString *model,
                                NSArray *messages, int timeoutSec) {
    if (!apiKey || ![apiKey length]) return nil;
    // 构造 body
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[BJCStr("model")] = model;
    payload[BJCStr("messages")] = messages;
    payload[BJCStr("temperature")] = @(0.7);
    payload[BJCStr("max_tokens")] = @(4096);
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!bodyData) return nil;
    
    NSURL *url = [NSURL URLWithString:baseURL];
    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url];
    [req setHTTPMethod:BJCStr("POST")];
    [req setValue:BJCStr("application/json") forHTTPHeaderField:BJCStr("Content-Type")];
    [req setValue:[NSString stringWithFormat:BJCStr("Bearer %@"), apiKey] forHTTPHeaderField:BJCStr("Authorization")];
    [req setHTTPBody:bodyData];
    [req setTimeoutInterval:timeoutSec];
    
    // 同步发送（deprecated 但可用，绕开 block/PAC 问题）
    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *respData = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    WXLog(BJCStr("AI resp(%@) status=%ld len=%lu err=%@"), model, (long)[resp statusCode],
          (unsigned long)[respData length], err);
    if (err || !respData) return nil;
    if ([resp statusCode] != 200) return nil;
    NSString *jsonStr = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
    return jsonStr;
}

// 单模型：DeepSeek（唯一 AI，用户指定）
static NSString *WXAIRequestChain(NSArray *messages, int timeoutSec) {
    return WXAIRequestURL(BJCStr("https://api.deepseek.com/chat/completions"),
                          BJCStr(WXDEEPSEEKKEY), BJCStr("deepseek-chat"), messages, timeoutSec);
}

// 解析 DeepSeek 响应 → 取 content
static NSString *WXAIExtractContent(NSString *jsonStr) {
    if (!jsonStr) return nil;
    NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!obj) return nil;
    NSArray *choices = obj[BJCStr("choices")];
    if (![choices count]) return nil;
    NSDictionary *first = choices[0];
    NSDictionary *msg = first[BJCStr("message")];
    if (!msg) return nil;
    NSString *content = msg[BJCStr("content")];
    return content;
}

// ============ AI 研究：选人+时间段 → 提取 → 分析 ============
// 前向声明（C 要求先声明后使用）
static void WXAICallback(void *ctx);
static void WXAICBEmpty(void *ctx);

// 在后台线程调用（避免卡 UI）；完成后主线程回调 JS
static void WXAIResearchMain(void *ctx) {
    // ctx 携带参数（用 autoreleasepool 保证内存）
    @autoreleasepool {
        NSArray *params = (__bridge_transfer NSArray *)ctx;
        NSString *db = params[0];
        NSString *table = params[1];
        NSString *name = params[2];
        long long startTs = [params[3] longLongValue];
        long long endTs = [params[4] longLongValue];
        long long cbId = [params[5] longLongValue];
        NSString *userQuestion = [params count] > 6 ? params[6] : @"";
        
        // 追问模式：已有对话历史，跳过消息提取，直接用历史
        if ([userQuestion length] && [WXAIHistory count]) {
            NSMutableArray *history = [NSMutableArray array];
            [history addObjectsFromArray:WXAIHistory];
            [history addObject:@{BJCStr("role"): BJCStr("user"), BJCStr("content"): userQuestion}];
            NSString *respJson = WXAIRequestChain(history, 120);
            NSString *content = WXAIExtractContent(respJson);
            if (content) {
                [WXAIHistory addObject:@{BJCStr("role"): BJCStr("user"), BJCStr("content"): userQuestion}];
                [WXAIHistory addObject:@{BJCStr("role"): BJCStr("assistant"), BJCStr("content"): content}];
            }
            NSMutableDictionary *cb = [NSMutableDictionary dictionary];
            cb[BJCStr("id")] = @(cbId);
            cb[BJCStr("ok")] = @(content != nil);
            cb[BJCStr("content")] = content ?: @"";
            if (!content) cb[BJCStr("error")] = respJson ?: BJCStr("API请求失败(检查Key/网络)");
            dispatch_async_f(dispatch_get_main_queue(), (void *)CFBridgingRetain(cb), (dispatch_function_t)WXAICallback);
            return;
        }
        
        // 1. 提取消息（最多 500 条，避免 token 爆炸）
        NSArray *msgs = WXFetchMessagesRange(db, table, startTs, endTs, 500);
        WXLog(BJCStr("AI fetch msgs=%lu start=%lld end=%lld"), (unsigned long)[msgs count], startTs, endTs);
        if (![msgs count]) {
            // 主线程回调"无消息"
            dispatch_async_f(dispatch_get_main_queue(), (void *)(long)cbId, (dispatch_function_t)WXAICBEmpty);
            return;
        }
        NSString *chatText = WXMessagesToText(msgs, BJCStr("我"), name);
        
        // 2. 构造 system + 聊天记录
        NSString *sysPrompt = [NSString stringWithFormat:BJCStr(
            "你是聊天记录研究助手。以下是「%@」的聊天记录（时间正序，格式：时间 发送者: 内容）。"
            "请从研究角度分析：1)主要话题和内容 2)关系状态与变化 3)重要事件/约定 4)值得注意的细节。"
            "用中文回复，条理清晰，不要编造记录里没有的内容。\n\n===聊天记录开始===\n%@\n===聊天记录结束==="),
            name, chatText];
        
        // 3. 维护对话历史（第一轮 system 固定；后续轮次带用户追问）
        NSMutableArray *history = [NSMutableArray array];
        if ([userQuestion length] && [WXAIHistory count]) {
            [history addObjectsFromArray:WXAIHistory];
            [history addObject:@{BJCStr("role"): BJCStr("user"), BJCStr("content"): userQuestion}];
        } else {
            [history addObject:@{BJCStr("role"): BJCStr("system"), BJCStr("content"): sysPrompt}];
            // 缩短系统提示给后续轮次用
            NSString *sysShort = [NSString stringWithFormat:BJCStr(
                "以下是「%@」的聊天记录，已作为对话上下文。回答用户关于这段聊天的问题，用中文。"), name];
            WXAIHistory = [NSMutableArray arrayWithObject:@{BJCStr("role"): BJCStr("system"), BJCStr("content"): sysShort}];
        }
        
        // 4. 调 DeepSeek API
        NSString *respJson = WXAIRequestChain(history, 120);
        NSString *content = WXAIExtractContent(respJson);
        
        if (content) {
            [WXAIHistory addObject:@{BJCStr("role"): BJCStr("user"), BJCStr("content"): userQuestion ?: BJCStr("分析这段聊天")}];
            [WXAIHistory addObject:@{BJCStr("role"): BJCStr("assistant"), BJCStr("content"): content}];
        }
        
        // 5. 主线程回调 JS
        NSMutableDictionary *cb = [NSMutableDictionary dictionary];
        cb[BJCStr("id")] = @(cbId);
        cb[BJCStr("ok")] = @(content != nil);
        cb[BJCStr("content")] = content ?: @"";
        if (!content) cb[BJCStr("error")] = respJson ?: BJCStr("API请求失败(检查Key/网络)");
        dispatch_async_f(dispatch_get_main_queue(), (void *)CFBridgingRetain(cb), (dispatch_function_t)WXAICallback);
    }
}

// 空结果回调
static void WXAICBEmpty(void *ctx) {
    @autoreleasepool {
        long long cbId = (long long)ctx;
        WKWebView *web = [WXPageVC view].subviews.count ? [WXPageVC view].subviews[0] : nil;
        if ([web isKindOfClass:[WKWebView class]]) {
            [web evaluateJavaScript:[NSString stringWithFormat:BJCStr("window.__aiCb(%lld, %@)"), cbId, @"{\"ok\":false,\"error\":\"该时间段没有消息\"}"] completionHandler:nil];
        }
    }
}

// AI 回调（主线程）
static void WXAICallback(void *ctx) {
    @autoreleasepool {
        NSDictionary *cb = (__bridge_transfer NSDictionary *)ctx;
        long long cbId = [cb[BJCStr("id")] longLongValue];
        NSString *content = cb[BJCStr("content")] ?: @"";
        BOOL ok = [cb[BJCStr("ok")] boolValue];
        NSString *err = cb[BJCStr("error")] ?: @"";
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[BJCStr("ok")] = @(ok);
        out[BJCStr("content")] = content;
        out[BJCStr("error")] = err;
        WXLog(BJCStr("AI cb ok=%d clen=%lu errLen=%lu"), ok, (unsigned long)[content length], (unsigned long)[err length]);
        NSData *json = [NSJSONSerialization dataWithJSONObject:WXJSONSafe(out) options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        // 找到 webview 回调
        UIView *v = BJ_MSG_SEND0(WXPageVC, sel_registerName("view"));
        for (UIView *sub in [v subviews]) {
            if ([sub isKindOfClass:[WKWebView class]]) {
                WKWebView *web = (WKWebView *)sub;
                [web evaluateJavaScript:[NSString stringWithFormat:BJCStr("window.__aiCb(%lld, '%@')"), cbId, WXJSEscape(jsonStr)] completionHandler:nil];
                break;
            }
        }
    }
}

// 启动 AI 研究（JS 桥调用入口）
static void WXStartAIResearch(NSString *db, NSString *table, NSString *name,
                              long long startTs, long long endTs, long long cbId, NSString *userQuestion) {
    NSMutableArray *params = [NSMutableArray array];
    [params addObject:db ?: @""];
    [params addObject:table ?: @""];
    [params addObject:name ?: @""];
    [params addObject:@(startTs)];
    [params addObject:@(endTs)];
    [params addObject:@(cbId)];
    if (userQuestion) [params addObject:userQuestion];
    // 后台队列执行（async 立即执行，after 需要 time 参数）
    dispatch_async_f(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                     (void *)CFBridgingRetain(params), (dispatch_function_t)WXAIResearchMain);
}


static NSArray *WXStatsByDay(NSString *db, NSString *table, int days) {
    NSString *sql = [NSString stringWithFormat:BJCStr(
        "SELECT strftime('%%Y-%%m-%%d', CreateTime, 'unixepoch', 'localtime') AS day, "
        "COUNT(*) AS cnt, SUM(CASE WHEN Type=1 THEN 1 ELSE 0 END) AS txt, "
        "SUM(CASE WHEN Type=3 THEN 1 ELSE 0 END) AS img, "
        "SUM(CASE WHEN Type=34 THEN 1 ELSE 0 END) AS voice "
        "FROM %@ WHERE CreateTime > strftime('%%s','now','localtime','-%d days') "
        "GROUP BY day ORDER BY day"), table, days];
    return WXQuery(db, sql, 0);
}

// ============ 消息统计（pkc 式）：分类 + 双方条数 ============
// 返回 [{Type:1,cnt:36,mine:22,theirs:14}, ...]（Type=0 为总计行）
static NSArray *WXStatsDetail(NSString *db, NSString *table, long long startTs, long long endTs) {
    NSString *sql = [NSString stringWithFormat:BJCStr(
        "SELECT * FROM ("
        "SELECT Type, COUNT(*) AS cnt, "
        "SUM(CASE WHEN Des=0 THEN 1 ELSE 0 END) AS mine, "
        "SUM(CASE WHEN Des=1 THEN 1 ELSE 0 END) AS theirs "
        "FROM %@ WHERE CreateTime BETWEEN %lld AND %lld GROUP BY Type "
        "UNION ALL SELECT 0, COUNT(*), "
        "SUM(CASE WHEN Des=0 THEN 1 ELSE 0 END), "
        "SUM(CASE WHEN Des=1 THEN 1 ELSE 0 END) "
        "FROM %@ WHERE CreateTime BETWEEN %lld AND %lld) "
        "ORDER BY CASE WHEN Type=0 THEN 0 ELSE 1 END, cnt DESC"),
        table, startTs, endTs, table, startTs, endTs];
    return WXQuery(db, sql, 0);
}

// ============ 群消息排名：按发送者 wxid 分组统计 ============
// 返回 [{sender:'wxid_xxx', name:'备注/昵称', cnt:23}, ...] 前 30
static NSArray *WXGroupRank(NSString *db, NSString *table, long long startTs, long long endTs) {
    NSString *sql = [NSString stringWithFormat:BJCStr(
        "SELECT substr(CAST(Message AS TEXT), 1, "
        "CASE WHEN instr(CAST(Message AS TEXT), ':') > 0 "
        "THEN instr(CAST(Message AS TEXT), ':') - 1 ELSE 0 END) AS sender, "
        "COUNT(*) AS cnt FROM %@ "
        "WHERE Des=1 AND Type IN (1,3,34,43,47,49) "
        "AND CreateTime BETWEEN %lld AND %lld "
        "AND sender != '' "
        "GROUP BY sender ORDER BY cnt DESC LIMIT 30"),
        table, startTs, endTs];
    NSArray *rows = WXQuery(db, sql, 0);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in rows) {
        NSString *sender = r[BJCStr("sender")] ?: @"";
        if (![sender length]) continue;
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:r];
        m[BJCStr("name")] = WXContactName(sender) ?: sender;
        [out addObject:m];
    }
    return out;
}

// ============ 复制文本到剪贴板（pkc 式"复制"按钮） ============
static void WXCopyText(NSString *text) {
    if (![text length]) return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    [pb setString:text];
}

// ============ 内嵌 HTML 页面 ============
static NSString *WXPageHTML(void) {
    return BJCStr(
    "<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1'>"
    "<style>"
    "*{margin:0;padding:0;box-sizing:border-box;font-family:-apple-system,system-ui}"
    "body{background:#f5f5f7;color:#111}"
    "@keyframes spin{to{transform:rotate(360deg)}}"
    ".nav{position:fixed;top:0;left:0;right:0;height:56px;background:rgba(255,255,255,.92);-webkit-backdrop-filter:blur(20px);display:flex;align-items:center;padding:0 10px;box-shadow:0 1px 4px rgba(0,0,0,.06);z-index:100}"
    ".nav h1{flex:1;font-size:17px;font-weight:600;text-align:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 6px}"
    ".nav button{background:none;border:none;font-size:16px;color:#07c160;padding:8px 10px;font-weight:500;white-space:nowrap}"
    "#content{margin-top:56px;padding:10px 0 90px}"
    ".sess{background:#fff;margin:8px 14px;border-radius:14px;padding:14px 16px;display:flex;align-items:center;box-shadow:0 1px 3px rgba(0,0,0,.06);transition:transform .15s;cursor:pointer}"
    ".sess:active{transform:scale(.98)}"
    ".avatar{width:46px;height:46px;border-radius:50%;color:#fff;display:flex;align-items:center;justify-content:center;font-size:19px;font-weight:600;flex-shrink:0;text-shadow:0 1px 2px rgba(0,0,0,.2)}"
    ".sess-mid{flex:1;margin-left:12px;overflow:hidden}"
    ".sess-name{font-size:16px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}"
    ".sess-last{font-size:13px;color:#999;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:4px}"
    ".sess-right{text-align:right;flex-shrink:0;margin-left:8px}"
    ".sess-time{font-size:12px;color:#bbb}"
    ".sess-cnt{font-size:12px;color:#07c160;margin-top:3px;background:#e8f8ee;padding:1px 6px;border-radius:8px}"
    ".day-sep{text-align:center;font-size:12px;color:#999;margin:16px 0 10px}"
    ".day-sep span{background:#e9e9eb;border-radius:8px;padding:3px 12px}"
    ".msg{display:flex;margin:10px 14px;align-items:flex-start}"
    ".msg.me{flex-direction:row-reverse}"
    ".bubble{max-width:68%;padding:10px 14px;border-radius:14px;font-size:16px;line-height:1.5;word-break:break-word;box-shadow:0 1px 2px rgba(0,0,0,.04)}"
    ".them .bubble{background:#fff;border-top-left-radius:4px}"
    ".me .bubble{background:#95ec69;border-top-right-radius:4px}"
    ".them .avatar{background:#9aa0a6;margin-right:10px;font-size:15px}"
    ".me .avatar{background:#07c160;margin-left:10px;font-size:15px}"
    ".mtime{font-size:11px;color:#bbb;margin:2px 8px;text-align:right}"
    ".nontext{color:#576b95}"
    "#searchBar,#sessSearch{position:fixed;top:56px;left:0;right:0;background:rgba(255,255,255,.95);padding:10px 14px;display:none;z-index:90;-webkit-backdrop-filter:blur(20px)}"
    "#searchBar input,#sessSearch input{width:100%;padding:10px 14px;border-radius:10px;border:1px solid #e5e5e5;font-size:15px;background:#f5f5f7;outline:none}"
    "#searchBar input:focus,#sessSearch input:focus{border-color:#07c160}"
    ".stat-day{display:flex;align-items:center;margin:4px 12px;font-size:13px}"
    ".stat-day .sd{width:80px;color:#666;flex-shrink:0}"
    ".stat-bar{height:16px;border-radius:4px;background:#07c160;margin-left:8px;min-width:2px}"
    ".stat-cnt{color:#999;margin-left:6px;white-space:nowrap}"
    ".loading{text-align:center;color:#999;font-size:13px;padding:18px}"
    ".loading .spin{display:inline-block;width:18px;height:18px;border:2px solid #ccc;border-top-color:#07c160;border-radius:50%;animation:spin .8s linear infinite;vertical-align:-4px;margin-right:6px}"
    ".empty{text-align:center;color:#bbb;font-size:14px;padding:60px 0}"
    "#fab{position:fixed;right:18px;bottom:90px;width:52px;height:52px;border-radius:50%;background:#07c160;color:#fff;font-size:28px;display:none;align-items:center;justify-content:center;box-shadow:0 4px 12px rgba(7,193,96,.4);z-index:80}"
    /* AI 研究 */
    ".ai-panel{background:#fff;border-radius:14px;margin:10px 14px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.06)}"
    ".ai-panel h3{font-size:15px;font-weight:600;margin-bottom:12px;color:#111}"
    ".ai-ranges{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:12px}"
    ".ai-ranges button{flex:1;min-width:60px;padding:9px 4px;border-radius:10px;border:1px solid #e5e5e5;background:#fff;font-size:13px;color:#333;transition:all .15s}"
    ".ai-ranges button.on{background:#07c160;border-color:#07c160;color:#fff}"
    ".ai-go{width:100%;padding:12px;border:none;border-radius:12px;background:#07c160;color:#fff;font-size:15px;font-weight:600;box-shadow:0 3px 8px rgba(7,193,96,.3)}"
    ".ai-go:disabled{background:#bbb;box-shadow:none}"
    ".ai-result{margin:10px 14px;padding:16px;background:#fff;border-radius:14px;font-size:15px;line-height:1.65;white-space:pre-wrap;word-break:break-word;box-shadow:0 1px 3px rgba(0,0,0,.06)}"
    ".ai-loading{text-align:center;color:#07c160;font-size:14px;padding:24px}"
    ".ai-loading .spin{display:inline-block;width:20px;height:20px;border:2.5px solid #d8f5e4;border-top-color:#07c160;border-radius:50%;animation:spin .8s linear infinite;vertical-align:-4px;margin-right:8px}"
    ".ai-error{text-align:center;color:#e64340;font-size:13px;padding:14px}"
    ".ai-inputbar{position:fixed;bottom:0;left:0;right:0;background:rgba(247,247,248,.95);padding:10px 14px;display:flex;gap:8px;border-top:1px solid #e5e5e5;z-index:95;-webkit-backdrop-filter:blur(20px)}"
    ".ai-inputbar input{flex:1;padding:10px 14px;border-radius:10px;border:1px solid #ddd;font-size:15px;background:#fff;outline:none}"
    ".ai-inputbar button{padding:10px 18px;border:none;border-radius:10px;background:#07c160;color:#fff;font-size:15px;font-weight:500}"
    ".ai-keynote{font-size:12px;color:#999;text-align:center;padding:8px 20px}"
    /* pkc 式统计弹窗/菜单 */
    ".mask{position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:200;display:none;align-items:flex-end;justify-content:center}"
    ".mask.show{display:flex}"
    ".sheet{background:#fff;border-radius:16px 16px 0 0;width:100%;max-width:480px;padding:10px 0 22px;animation:slideup .22s ease}"
    "@keyframes slideup{from{transform:translateY(60px);opacity:.4}to{transform:translateY(0);opacity:1}}"
    ".sheet-title{text-align:center;font-size:15px;font-weight:600;color:#111;padding:12px 0 6px}"
    ".sheet-item{display:flex;align-items:center;justify-content:space-between;padding:15px 24px;font-size:16px;color:#111;border-bottom:1px solid #f2f2f2;cursor:pointer}"
    ".sheet-item:active{background:#f5f5f7}"
    ".sheet-item .si-arrow{color:#c8c8c8;font-size:14px}"
    ".sheet-cancel{text-align:center;padding:15px;font-size:16px;color:#888;margin-top:8px;cursor:pointer;border-top:1px solid #f2f2f2}"
    ".modal-card{background:#fff;border-radius:14px;width:88%;max-width:400px;margin:auto auto 30px;overflow:hidden;box-shadow:0 10px 40px rgba(0,0,0,.3);animation:popin .2s ease}"
    "@keyframes popin{from{transform:scale(.9);opacity:.5}to{transform:scale(1);opacity:1}}"
    ".modal-head{background:#f7f7f7;padding:18px 20px;border-bottom:1px solid #eee}"
    ".modal-head h3{font-size:17px;font-weight:600;text-align:center}"
    ".modal-head .sub{font-size:12px;color:#999;text-align:center;margin-top:4px}"
    ".stat-line{display:flex;justify-content:space-between;padding:13px 20px;font-size:15px;border-bottom:1px solid #f5f5f5}"
    ".stat-line .sl-name{color:#333}"
    ".stat-line .sl-cnt{color:#07c160;font-weight:600}"
    ".stat-line .sl-mine{color:#999;font-size:13px;margin-left:8px}"
    ".stat-total{display:flex;justify-content:space-between;padding:14px 20px;background:#fbfbfb;font-size:15px;font-weight:600}"
    ".modal-actions{display:flex;border-top:1px solid #eee}"
    ".modal-actions button{flex:1;padding:14px 0;border:none;background:#fff;font-size:15px;color:#111;cursor:pointer}"
    ".modal-actions button+button{border-left:1px solid #eee}"
    ".modal-actions button.green{color:#07c160;font-weight:600}"
    ".modal-actions button:active{background:#f5f5f7}"
    ".modal-read{text-align:center;padding:10px;font-size:12px;color:#bbb;background:#fbfbfb;border-top:1px solid #f2f2f2}"
    ".rank-row{display:flex;align-items:center;padding:12px 20px;font-size:15px;border-bottom:1px solid #f5f5f5;gap:10px}"
    ".rank-row .rk{width:26px;height:26px;border-radius:50%;background:#f2f2f2;color:#666;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:600;flex-shrink:0}"
    ".rank-row .rk.top{background:#ffd60a;color:#333}"
    ".rank-row .rk.top2{background:#e5e5ea;color:#555}"
    ".rank-row .rk.top3{background:#e8b48a;color:#fff}"
    ".rank-row .rk-name{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}"
    ".rank-row .rk-cnt{color:#07c160;font-weight:600}"
    ".date-row{display:flex;gap:8px;padding:14px 20px}"
    ".date-row input{flex:1;padding:9px;border:1px solid #ddd;border-radius:8px;font-size:13px;background:#fff;color:#333}"
    "</style></head><body>"
    "<div class='nav'><button onclick='goBack()' id='backBtn' style='visibility:hidden'>返回</button>"
    "<h1 id='title'>聊天研究</h1>"
    "<button id='searchBtn' onclick='toggleSearch()' style='visibility:hidden'>搜索</button>"
    "<button id='statsBtn' onclick='openStatsMenu()' style='visibility:hidden;color:#576b95'>📊统计</button>"
    "<button id='aiBtn' onclick='openAI()' style='visibility:hidden;color:#576b95'>AI研究</button>"
    "<button id='timeBtn' onclick='openTimeMenu()' style='visibility:hidden;color:#e64340;font-size:12px'>全部</button></div>"
    "<div id='statsMask' class='mask'><div id='statsSheet' class='sheet'></div></div>"
    "<div id='searchBar'><input id='kw' placeholder='搜索聊天记录…' oninput='onSearch(this.value)'></div>"
    "<div id='sessSearch'><input id='skw' placeholder='搜备注/名字/微信号' oninput='onSessSearch(this.value)'></div>"
    "<div id='content'></div>"
    "<div id='fab' onclick='goTop()'>↑</div>"
    "<script>"
    "var reqId=0;var pending={};"
    "function repErr(t){try{webkit.messageHandlers.wxResearch.postMessage({id:++reqId,action:'jsdebug',p1:t});}catch(e){}var d=document.getElementById('content');if(d)d.innerHTML='<div class=empty style=color:#e64340>'+t+'</div>';}"
    "window.onerror=function(m,s,l,c){repErr('JS错误:'+String(m)+' @'+(l||'')+':'+(c||''));return false;};"
    "var state={view:'sessions',table:'',db:'',name:'',offset:0,loading:false,all:false,kw:''};"
    "function post(a){return new Promise(function(res,rej){var id=++reqId;pending[id]=res;"
    "try{webkit.messageHandlers.wxResearch.postMessage({id:id,action:a.action,p1:a.p1,p2:a.p2,p3:a.p3,p4:a.p4});}"
    "catch(e){delete pending[id];rej(e);repErr('桥失败:'+a.action+' '+e.message);}});}"
    "window.__cb=function(id,json){var p=pending[id];if(p){delete pending[id];p(JSON.parse(json));}};"
    "function esc(s){return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\\\"/g,'&quot;');}"
    "var AV_COLORS=['#07c160','#10aeff','#ff9f0a','#ff453a','#bf5af2','#5e5ce6','#ff375f','#30d158','#64d2ff','#ffd60a','#ff9500','#00c7be'];"
    "function avColor(s){var h=0;for(var i=0;i<s.length;i++)h=(h*31+s.charCodeAt(i))>>>0;return AV_COLORS[h%AV_COLORS.length];}"
    "function fmtTime(ts){if(!ts)return'';var d=new Date(ts*1000);var now=new Date();"
    "if(d.toDateString()===now.toDateString())return(d.getHours()<10?'0':'')+d.getHours()+':'+(d.getMinutes()<10?'0':'')+d.getMinutes();"
    "return(d.getMonth()+1)+'/'+d.getDate();}"
    "function fmtDay(ts){var d=new Date(ts*1000);var now=new Date();var yest=new Date(now.getTime()-86400000);"
    "if(d.toDateString()===now.toDateString())return'今天';if(d.toDateString()===yest.toDateString())return'昨天';"
    "return d.getFullYear()+'年'+(d.getMonth()+1)+'月'+d.getDate()+'日';}"
    "var TYPE_LABEL={1:'',3:'[图片]',34:'[语音]',43:'[视频]',47:'[表情]',49:'[链接]',50:'[语音通话]',10000:'[系统消息]'};"
    "function fmtMsg(t,msg){if(t===1||t===10000){var s=String(msg);s=s.replace(/^wxid_[^:\\r\\n]+[\\r\\n]+/,'');return esc(s);}if(t===49){"
    "var m=msg.match(/<title>([^<]*)<\\/title>/);return'[链接] '+(m?esc(m[1]):'分享');}"
    "return TYPE_LABEL[t]||('[消息'+t+']');}"
    "function loadSessions(){state.view='sessions';"
    "document.getElementById('title').textContent='聊天研究';"
    "document.getElementById('backBtn').style.visibility='hidden';"
    "document.getElementById('searchBtn').style.visibility='hidden';"
    "document.getElementById('searchBar').style.display='none';"
    "document.getElementById('sessSearch').style.display='block';"
    "document.getElementById('content').innerHTML='<div class=loading><span class=spin></span>加载会话…</div>';"
    "post({action:'sessions'}).then(function(list){"
    "window._sessList=list;"
    "var html='';for(var i=0;i<list.length;i++){var s=list[i];var nm=String(s.name||'');var ch=nm.charAt(0)||'?';"
    "html+='<div class=sess onclick=openSess('+i+')>'"
    "+'<div class=avatar style=\"background:'+avColor(nm)+'\">'+esc(ch)+'</div>'+'<div class=sess-mid>'+'<div class=sess-name>'+esc(nm)+'</div>'"
    "+'<div class=sess-last>'+esc(s.userName||'')+'</div></div>'+'<div class=sess-right><div class=sess-time>'+fmtTime(s.lastTime)+'</div>'"
    "+'</div></div>';}"
    "document.getElementById('content').innerHTML=html||'<div class=empty>没有找到聊天记录</div>';});}"
    "function onSessSearch(v){v=v.trim();if(!v){loadSessions();return;}"
    "document.getElementById('content').innerHTML='<div class=loading><span class=spin></span>搜索会话…</div>';"
    "post({action:'search_sessions',p1:v}).then(function(list){"
    "window._sessList=list;"
    "var html='';for(var i=0;i<list.length;i++){var s=list[i];var nm=String(s.name||'');var ch=nm.charAt(0)||'?';"
    "html+='<div class=sess onclick=openSess('+i+')>'"
    "+'<div class=avatar style=\"background:'+avColor(nm)+'\">'+esc(ch)+'</div>'+'<div class=sess-mid>'+'<div class=sess-name>'+esc(nm)+'</div>'"
    "+'<div class=sess-last>'+esc(s.userName||'')+'</div></div>'+'<div class=sess-right><div class=sess-time>'+fmtTime(s.lastTime)+'</div>'"
    "+'</div></div>';}"
    "document.getElementById('content').innerHTML=html||'<div class=empty>没有找到相关会话</div>';});}"
    "function openSess(i){var s=window._sessList[i];state.view='chat';state.table=s.table;state.db=s.db;state.name=s.name;state.offset=0;state.all=false;state.kw='';state.range=[0,0];"
    "document.getElementById('title').textContent=s.name;"
    "document.getElementById('backBtn').style.visibility='visible';"
    "document.getElementById('searchBtn').style.visibility='visible';"
    "document.getElementById('statsBtn').style.visibility='visible';"
    "document.getElementById('aiBtn').style.visibility='visible';"
    "document.getElementById('timeBtn').style.visibility='visible';"
    "document.getElementById('timeBtn').textContent='全部';"
    "document.getElementById('searchBar').style.display='none';"
    "document.getElementById('sessSearch').style.display='none';"
    "document.getElementById('kw').value='';"
    "document.getElementById('content').innerHTML='';loadMore();}"
    "function loadMore(){if(state.view!=='chat'||state.loading||state.all)return;state.loading=true;"
    "var p3=String(state.offset);if(state.range[1]>state.range[0])p3=state.offset+'|'+state.range[0]+'|'+state.range[1];"
    "post({action:'messages',p1:state.db,p2:state.table,p3:p3,p4:50}).then(function(batch){"
    "state.loading=false;if(!batch.length){state.all=true;}"
    "state.offset+=batch.length;var c=document.getElementById('content');"
    "var html='';var lastDay='';for(var i=0;i<batch.length;i++){var m=batch[i];"
    "var d=fmtDay(m.CreateTime);if(d!==lastDay){html+='<div class=day-sep><span>'+d+'</span></div>';lastDay=d;}"
    "var cls=m.isMe?'me':'them';var body=fmtMsg(m.Type,m.Message);"
    "html+='<div class=\"msg '+cls+'\\\"><div class=avatar>'+esc((m.isMe?'我':'她'))+'</div>'"
    "+'<div class=bubble>'+body+'</div></div><div class=\"mtime '+cls+'\\\">'+fmtTime(m.CreateTime)+'</div>';}"
    "c.insertAdjacentHTML('beforeend',html);"
    "if(!state.all&&batch.length)c.insertAdjacentHTML('beforeend','<div class=loading><span class=spin></span>上滑加载更多…</div>');});}"
    "function toggleSearch(){var sb=document.getElementById('searchBar');"
    "sb.style.display=sb.style.display==='none'?'block':'none';if(sb.style.display==='block')document.getElementById('kw').focus();}"
    "function onSearch(v){state.kw=v;if(!v){loadSessions();return;}"
    "post({action:'search',p1:state.db,p2:state.table,p3:v,p4:100}).then(function(hits){"
    "var html='';for(var i=0;i<hits.length;i++){var m=hits[i];"
    "html+='<div class=msg '+(m.isMe?'me':'them')+'><div class=bubble>'+fmtMsg(m.Type,m.Message)+'</div></div>'"
    "+'<div class=mtime>'+fmtDay(m.CreateTime)+' '+fmtTime(m.CreateTime)+'</div>';}"
    "document.getElementById('content').innerHTML=html||'<div class=empty>没有找到相关消息</div>';});}"
    "function goBack(){if(state.view==='chat'){loadSessions();}else if(state.view==='ai'){showChat();}else{post({action:'close'});}}"
    "/* ============ pkc 式消息统计 ============ */"
    "function closeStats(){var m=document.getElementById('statsMask');if(m)m.className='mask';}"
    "function statsReady(){var m=document.getElementById('statsMask');if(!m){var d=document.createElement('div');d.id='statsMask';d.className='mask';d.innerHTML='<div id=statsSheet class=sheet></div>';document.body.appendChild(d);m=d;}else if(!document.getElementById('statsSheet')){m.innerHTML='<div id=statsSheet class=sheet></div>';}return m;}"
    "function openTimeMenu(){"
    "var html='<div class=sheet-title>⏱ 查看时间段</div>';"
    "var items=[['全部','all'],['今天','today'],['昨天','yest'],['近3天','3'],['近7天','7'],['近1月','30'],['自定义日期','custom']];"
    "for(var i=0;i<items.length;i++){"
    "html+='<div class=sheet-item onclick=timePick(\\''+items[i][1]+'\\')>'+items[i][0]+'<span class=si-arrow>›</span></div>';}"
    "html+='<div class=sheet-cancel onclick=closeStats()>取消</div>';"
    "var mm=statsReady();document.getElementById('statsSheet').innerHTML=html;mm.className='mask show';}"
    "function timePick(kind){"
    "var now=new Date();var start=0,end=0;"
    "if(kind==='today'){var d=new Date(now);d.setHours(0,0,0,0);start=d.getTime()/1000;end=now.getTime()/1000;}"
    "else if(kind==='yest'){var d=new Date(now);d.setHours(0,0,0,0);var d2=new Date(d.getTime()-86400000);start=d2.getTime()/1000;end=d.getTime()/1000;}"
    "else if(kind==='3'||kind==='7'||kind==='30'){end=now.getTime()/1000;start=end-parseInt(kind)*86400;}"
    "else if(kind==='custom'){openTimeCustom();return;}"
    "applyTimeRange(start,end,kind);}"
    "function openTimeCustom(){"
    "var today=new Date();var t=today.getFullYear()+'-'+((today.getMonth()+1)<10?'0':'')+(today.getMonth()+1)+'-'+((today.getDate()<10)?'0':'')+today.getDate();"
    "var html='<div class=sheet-title>自定义日期</div>'"
    "+\"<div class=date-row><input type=date id=dStart max='\"+t+\"' value='\"+t+\"'><input type=date id=dEnd max='\"+t+\"' value='\"+t+\"'></div>\""
    "+'<div class=sheet-cancel onclick=doTimeCustom() style=color:#07c160;font-weight:600>确定</div>'"
    "+'<div class=sheet-cancel onclick=closeStats()>取消</div>';"
    "var mm2=statsReady();document.getElementById('statsSheet').innerHTML=html;mm2.className='mask show';}"
    "function doTimeCustom(){"
    "var s=document.getElementById('dStart').value;var e=document.getElementById('dEnd').value;"
    "if(!s||!e||e<s){alert('日期无效');return;}"
    "var sT=new Date(s+'T00:00:00').getTime()/1000;"
    "var eT=new Date(e+'T23:59:59').getTime()/1000;"
    "applyTimeRange(sT,eT,'custom');}"
    "function applyTimeRange(start,end,label){"
    "closeStats();state.range=[start,end];state.offset=0;state.all=false;"
    "var names={all:'全部',today:'今天',yest:'昨天','3':'近3天','7':'近7天','30':'近1月',custom:'自定义'};"
    "document.getElementById('timeBtn').textContent=names[label]||'自定义';"
    "document.getElementById('content').innerHTML='';loadMore();}"
    "function openStatsMenu(){"
    "var html='<div class=sheet-title>📊 消息统计</div>';"
    "var items=[['今天','today'],['昨天','yest'],['近1周','7'],['近1月','30'],['近1年','365'],['自定义范围','custom'],['群消息排名','group']];"
    "for(var i=0;i<items.length;i++){"
    "html+='<div class=sheet-item onclick=statsPick(\\''+items[i][1]+'\\')>'+items[i][0]+'<span class=si-arrow>›</span></div>';}"
    "html+='<div class=sheet-cancel onclick=closeStats()>取消</div>';"
    "var mm=statsReady();document.getElementById('statsSheet').innerHTML=html;mm.className='mask show';}"
    "function statsPick(kind){"
    "var now=new Date();var start,end;"
    "if(kind==='today'){var d=new Date(now);d.setHours(0,0,0,0);start=d.getTime()/1000;end=now.getTime()/1000;}"
    "else if(kind==='yest'){var d=new Date(now);d.setHours(0,0,0,0);var d2=new Date(d.getTime()-86400000);start=d2.getTime()/1000;end=d.getTime()/1000;}"
    "else if(kind==='7'||kind==='30'||kind==='365'){end=now.getTime()/1000;start=end-parseInt(kind)*86400;}"
    "else if(kind==='custom'){openCustomRange();return;}"
    "else if(kind==='group'){loadGroupRank(0,now.getTime()/1000);return;}"
    "loadStats(start,end);}"
    "function openCustomRange(){"
    "var today=new Date();var t=today.getFullYear()+'-'+((today.getMonth()+1)<10?'0':'')+(today.getMonth()+1)+'-'+((today.getDate()<10)?'0':'')+today.getDate();"
    "var html='<div class=sheet-title>自定义时间范围</div>'"
    "+\"<div class=date-row><input type=date id=dStart max='\"+t+\"' value='\"+t+\"'><input type=date id=dEnd max='\"+t+\"' value='\"+t+\"'></div>\""
    "+'<div class=sheet-cancel onclick=doCustomRange() style=color:#07c160;font-weight:600>确定</div>'"
    "+'<div class=sheet-cancel onclick=closeStats()>取消</div>';"
    "var mm2=statsReady();document.getElementById('statsSheet').innerHTML=html;mm2.className='mask show';}"
    "function doCustomRange(){"
    "var s=document.getElementById('dStart').value;var e=document.getElementById('dEnd').value;"
    "if(!s||!e||e<s){alert('日期无效');return;}"
    "var sT=new Date(s+'T00:00:00').getTime()/1000;"
    "var eT=new Date(e+'T23:59:59').getTime()/1000;"
    "loadStats(sT,eT);}"
    "function loadStats(start,end){closeStats();"
    "document.getElementById('content').innerHTML='<div class=loading><span class=spin></span>统计中…</div>';"
    "post({action:'stats_detail',p1:state.db,p2:state.table,p3:String(Math.floor(start)),p4:Math.floor(end)}).then(function(rows){renderStats(rows,start,end);});}"
    "function renderStats(rows,start,end){"
    "var TYPE_N={1:'文本',3:'图片',34:'语音',43:'视频',47:'表情',49:'链接',50:'通话',10000:'系统'};"
    "var total=rows.length?rows[0]:null;var totalCnt=total?total.cnt:0;var mine=total?total.mine:0;var theirs=total?total.theirs:0;"
    "function fmtRange(){var s=new Date(start*1000),e=new Date(end*1000);"
    "function md(d){return(d.getMonth()+1)+'/'+d.getDate();}"
    "if(start===0)return'全部记录';var days=Math.round((end-start)/86400);"
    "if(days<=1)return md(s);return md(s)+' 至 '+md(e);}"
    "var mm=statsReady();var sh=document.getElementById('statsSheet');"
    "sh.innerHTML='<div class=modal-card><div class=modal-head><h3>消息统计</h3><div class=sub>'+fmtRange()+'</div></div>';"
    "var card=sh.querySelector('.modal-card');"
    "for(var i=1;i<rows.length;i++){var r=rows[i];var nm=TYPE_N[r.Type]||('类型'+r.Type);"
    "card.innerHTML+='<div class=stat-line><span class=sl-name>'+nm+'</span><span><span class=sl-cnt>'+r.cnt+'</span><span class=sl-mine>我'+r.mine+' / 对方'+r.theirs+'</span></span></div>';}"
    "card.innerHTML+='<div class=stat-total><span>总计 '+totalCnt+' 条</span><span>我 '+mine+' / 对方 '+theirs+'</span></div>';"
    "card.innerHTML+='<div class=modal-actions>'+'<button onclick=closeStats()>关闭</button>'"
    "+'<button onclick=copyStats('+start+','+end+')>复制</button>'"
    "+'<button class=green onclick=statsToAI('+start+','+end+')>AI分析</button></div>'"
    "+'<div class=modal-read>已阅</div>';"
    "mm.className='mask show';}"
    "function copyStats(start,end){"
    "post({action:'stats_detail',p1:state.db,p2:state.table,p3:String(Math.floor(start)),p4:Math.floor(end)}).then(function(rows){"
    "var TYPE_N={1:'文本',3:'图片',34:'语音',43:'视频',47:'表情',49:'链接',50:'通话',10000:'系统'};"
    "var total=rows.length?rows[0]:null;var txt='消息统计\\n';"
    "for(var i=1;i<rows.length;i++){var r=rows[i];txt+=TYPE_N[r.Type]+': '+r.cnt+' (我'+r.mine+' 对方'+r.theirs+')\\n';}"
    "txt+='总计: '+total.cnt+' (我'+total.mine+' 对方'+total.theirs+')';"
    "post({action:'copy_text',p1:txt}).then(function(){closeStats();alert('已复制到剪贴板');});});}"
    "function statsToAI(start,end){closeStats();"
    "state.view='ai';document.getElementById('title').textContent='AI研究 - '+state.name;"
    "document.getElementById('backBtn').style.visibility='visible';"
    "document.getElementById('searchBtn').style.visibility='hidden';"
    "document.getElementById('aiBtn').style.visibility='hidden';"
    "document.getElementById('searchBar').style.display='none';"
    "aiMsgs=[];aiRange=0;"
    "var html='<div class=ai-panel><h3>研究「'+esc(state.name)+'」'+fmtRangeLabel(start,end)+'</h3>';"
    "html+='<button class=ai-go onclick=startAIRange('+Math.floor(start)+','+Math.floor(end)+')>开始分析</button></div>';"
    "document.getElementById('content').innerHTML=html;}"
    "function fmtRangeLabel(s,e){var a=new Date(s*1000),b=new Date(e*1000);"
    "function md(d){return(d.getMonth()+1)+'/'+d.getDate();}return'('+md(a)+'-'+md(b)+')';}"
    "function startAIRange(start,end){if(aiBusy)return;aiBusy=true;"
    "document.getElementById('content').innerHTML='<div class=ai-loading><span class=spin></span>正在提取聊天记录并交给AI分析…</div>';"
    "post({action:'ai_research',p1:state.db,p2:state.table,p3:state.name+'|'+Math.floor(start)+'|'+Math.floor(end),p4:0});}"
    "function loadGroupRank(start,end){closeStats();"
    "document.getElementById('content').innerHTML='<div class=loading><span class=spin></span>统计中…</div>';"
    "post({action:'group_rank',p1:state.db,p2:state.table,p3:String(Math.floor(start)),p4:Math.floor(end)}).then(function(rows){"
    "var html='<div class=ai-panel><h3>👥 群消息排行</h3><div class=ai-keynote>按发送条数排序</div></div>';"
    "if(!rows.length)html+='<div class=empty>该时段没有群消息</div>';"
    "for(var i=0;i<rows.length;i++){var r=rows[i];var rk=i<3?('rk top'+(i+1)):'rk';"
    "html+='<div class=rank-row><span class=\"'+rk+'\">'+(i+1)+'</span><span class=rk-name>'+esc(r.name)+'</span><span class=rk-cnt>'+r.cnt+'条</span></div>';}"
    "html+='<div style=text-align:center;padding:14px><button class=ai-go onclick=showChat() style=width:60%>返回聊天</button></div>';"
    "document.getElementById('content').innerHTML=html;});}"
    "function goTop(){window.scrollTo(0,0);}"
    "var aiRange=0;var aiBusy=false;var aiMsgs=[];"
    "window.__aiCb=function(id,obj){var btn=document.querySelector('.ai-go');if(btn)btn.disabled=false;"
    "if(!obj.ok){document.getElementById('content').innerHTML='<div class=ai-error>'+esc(obj.error||'失败')+'</div>';aiBusy=false;return;}"
    "aiMsgs.push({role:'ai',content:obj.content});renderAIResult();aiBusy=false;};"
    "function openAI(){state.view='ai';document.getElementById('title').textContent='AI研究 - '+state.name;"
    "document.getElementById('backBtn').style.visibility='visible';"
    "document.getElementById('searchBtn').style.visibility='hidden';"
    "document.getElementById('statsBtn').style.visibility='hidden';"
    "document.getElementById('aiBtn').style.visibility='hidden';"
    "document.getElementById('searchBar').style.display='none';"
    "aiMsgs=[];aiRange=0;"
    "post({action:'ai_getkey'}).then(function(k){var cfg=k.length&&k[0].configured;var mk=k.length?k[0].masked:'';"
    "var html='<div class=ai-panel><h3>研究「'+esc(state.name)+'」的聊天记录</h3>';"
    "html+='<div class=ai-ranges id=aiRanges>';"
    "html+='<button onclick=setRange(0,this) class=on>全部</button>';"
    "html+='<button onclick=setRange(1,this)>今天</button>';"
    "html+='<button onclick=setRange(7,this)>近7天</button>';"
    "html+='<button onclick=setRange(30,this)>近30天</button>';"
    "html+='<button onclick=setRange(90,this)>近90天</button>';"
    "html+='<button onclick=setRange(365,this)>近1年</button>';"
    "html+='<button onclick=openAITimeCustom()>自定义日期</button></div>';"
    "html+='<div class=ai-keynote>AI 引擎：DeepSeek（deepseek-chat），按用量计费</div>';"
    "html+='<button class=ai-go onclick=startAI()>开始分析</button>';"
    "html+='<button class=ai-go onclick=testAI() style=background:#576b95;box-shadow:none>🔌 测试AI连通性</button>';"
    "html+='<div id=aiTestResult></div>';"
    "html+='</div>';"
    "document.getElementById('content').innerHTML=html;"
    "document.getElementById('searchBtn').style.visibility='hidden';"
    "document.getElementById('aiBtn').style.visibility='hidden';});}"
    "function testAI(){var box=document.getElementById('aiTestResult');"
    "box.innerHTML='<div class=ai-loading><span class=spin></span>正在逐个测试 3 个模型…</div>';"
    "post({action:'ai_test'}).then(function(r){var d=r[0]||{};var rs=d.results||[];"
    "var h='<div style=margin-top:10px;background:#f7f7f7;border-radius:10px;padding:10px>';"
    "for(var i=0;i<rs.length;i++){var m=rs[i];"
    "h+='<div style=padding:6px 4px;border-bottom:1px solid #eee;font-size:13px>'"
    "+'<span style=color:'+(m.ok?'#07c160':'#fa5151')+'>'+(m.ok?'●':'○')+'</span> '"
    "+'<b>'+esc(m.name)+'</b> <span style=color:#888>'+esc(m.model)+'</span> — '"
    "+(m.ok?'<span style=color:#07c160>正常</span>':'<span style=color:#fa5151>失败</span>')"
    "+'<div style=color:#999;font-size:12px;margin-top:2px>'+esc(m.reply||'')+'</div></div>';}"
    "h+='</div>';box.innerHTML=h;});}"
    "function setRange(d,btn){if(d===1){var now=new Date();var t0=new Date(now);t0.setHours(0,0,0,0);aiRange=[t0.getTime()/1000,now.getTime()/1000];}else if(d>1){aiRange=[Math.floor(Date.now()/1000)-d*86400,Math.floor(Date.now()/1000)];}else{aiRange=0;}"
    "var bs=document.querySelectorAll('#aiRanges button');"
    "for(var i=0;i<bs.length;i++)bs[i].className='';if(btn)btn.className='on';}"
    "function openAITimeCustom(){"
    "var today=new Date();var t=today.getFullYear()+'-'+((today.getMonth()+1)<10?'0':'')+(today.getMonth()+1)+'-'+((today.getDate()<10)?'0':'')+today.getDate();"
    "var html='<div class=sheet-title>自定义日期</div>'"
    "+\"<div class=date-row><input type=date id=dStart max='\"+t+\"' value='\"+t+\"'><input type=date id=dEnd max='\"+t+\"' value='\"+t+\"'></div>\""
    "+'<div class=sheet-cancel onclick=doAITimeCustom() style=color:#07c160;font-weight:600>确定</div>'"
    "+'<div class=sheet-cancel onclick=closeStats()>取消</div>';"
    "var mm2=statsReady();document.getElementById('statsSheet').innerHTML=html;mm2.className='mask show';}"
    "function doAITimeCustom(){"
    "var s=document.getElementById('dStart').value;var e=document.getElementById('dEnd').value;"
    "if(!s||!e||e<s){alert('日期无效');return;}"
    "aiRange=[new Date(s+'T00:00:00').getTime()/1000,new Date(e+'T23:59:59').getTime()/1000];"
    "closeStats();var bs=document.querySelectorAll('#aiRanges button');for(var i=0;i<bs.length;i++)bs[i].className='';}"
    "function saveKey(){var k=document.getElementById('keyInput').value.trim();if(!k)return;"
    "post({action:'ai_setkey',p1:k}).then(function(){startAI();});}"
    "function startAI(){if(aiBusy)return;aiBusy=true;"
    "var btn=document.querySelector('.ai-go');if(btn)btn.disabled=true;"
    "document.getElementById('content').innerHTML='<div class=ai-loading><span class=spin></span>正在提取聊天记录并交给AI分析…</div>';"
    "var p3=state.name;var p4=0;"
    "if(aiRange&&aiRange.length===2){p3=state.name+'|'+Math.floor(aiRange[0])+'|'+Math.floor(aiRange[1]);p4=0;}"
    "else{p4=aiRange||0;}"
    "post({action:'ai_research',p1:state.db,p2:state.table,p3:p3,p4:p4});}"
    "function showChat(){state.view='chat';document.getElementById('title').textContent=state.name;"
    "document.getElementById('backBtn').style.visibility='visible';"
    "document.getElementById('searchBtn').style.visibility='visible';"
    "document.getElementById('statsBtn').style.visibility='visible';"
    "document.getElementById('aiBtn').style.visibility='visible';"
    "document.getElementById('searchBar').style.display='none';"
    "document.getElementById('sessSearch').style.display='none';"
    "document.getElementById('content').innerHTML='';state.offset=0;state.all=false;loadMore();}"
    "function showNoChat(msg){state.view='nochat';document.getElementById('title').textContent='聊天研究';"
    "document.getElementById('backBtn').style.visibility='hidden';"
    "document.getElementById('searchBtn').style.visibility='hidden';"
    "document.getElementById('statsBtn').style.visibility='hidden';"
    "document.getElementById('aiBtn').style.visibility='hidden';"
    "document.getElementById('searchBar').style.display='none';"
    "document.getElementById('sessSearch').style.display='none';"
    "document.getElementById('content').innerHTML='<div style=padding:80px 30px;text-align:center>'"
    " +'<div style=font-size:56px;margin-bottom:20px>🔍</div>'"
    " +'<div style=font-size:18px;font-weight:600;color:#333;margin-bottom:10px>'+esc(msg||'请进入联系人或群内再开启')+'</div>'"
    " +'<div style=font-size:13px;color:#999;line-height:1.7>进入任意联系人/群聊天页后<br>点击悬浮球「研」即可研究该会话</div>'"
    " +'<button style=margin-top:24px;padding:12px 32px;border:none;border-radius:12px;background:#07c160;color:#fff;font-size:15px;font-weight:600 onclick=loadSessions()>浏览全部会话</button></div>';}"
    "function init(){post({action:'current_chat'}).then(function(r){var d=r[0]||{};"
    "if(!d.ok){showNoChat(d.msg||'请进入联系人或群内再开启');loadSessions();return;}"
    "state.db=d.db;state.table=d.table;state.name=d.name||d.userName;"
    "showChat();openAI();});}"
    "function renderAIResult(){var html='';"
    "for(var i=0;i<aiMsgs.length;i++){var m=aiMsgs[i];"
    "if(m.role==='ai')html+='<div class=ai-result>'+m.content+'</div>';"
    "else html+='<div class=ai-result style=background:#e8f8ee>'+esc(m.content)+'</div>';}"
    "html+='<div class=ai-inputbar><input id=aiInput placeholder=\"继续追问这段聊天…\" onkeydown=if(event.key===\"Enter\")aiAsk()>"
    "<button onclick=aiAsk()>发送</button></div>';"
    "document.getElementById('content').innerHTML=html;"
    "var inp=document.getElementById('aiInput');if(inp)inp.focus();}"
    "function aiAsk(){var inp=document.getElementById('aiInput');var q=inp.value.trim();if(!q||aiBusy)return;"
    "aiBusy=true;aiMsgs.push({role:'me',content:q});inp.value='';renderAIResult();"
    "document.getElementById('content').insertAdjacentHTML('beforeend','<div class=ai-loading>AI思考中…</div>');"
    "post({action:'ai_chat',p1:q});}"
    "function goTop(){window.scrollTo(0,0);}"
    "window.onscroll=function(){if(window.innerHeight+window.scrollY>=document.body.scrollHeight-200)loadMore();};"
    "init();"
    "</script></body></html>");
}

// ============ JS 桥（动态类，WKScriptMessageHandler） ============
static void WXOnScriptMessage(id self, SEL _cmd, WKUserContentController *uc, WKScriptMessage *msg) {
    @autoreleasepool {
        NSDictionary *body = [msg body];
        NSString *action = body[BJCStr("action")];
        long long rid = [body[BJCStr("id")] longLongValue];
        NSString *p1 = body[BJCStr("p1")] ?: @"";
        NSString *p2 = body[BJCStr("p2")] ?: @"";
        NSString *p3 = body[BJCStr("p3")] ?: @"";
        long long p4 = [body[BJCStr("p4")] longLongValue];
        NSLog(BJCStr("[wxresearch] action=%@ rid=%lld p1=%@ p2=%@ p4=%lld"), action, rid,
              [p1 length] > 60 ? [p1 substringToIndex:60] : p1,
              [p2 length] > 60 ? [p2 substringToIndex:60] : p2, p4);
        WXLog(BJCStr("action=%@ rid=%lld p1=%@ p2=%@ p4=%lld"), action, rid,
              [p1 length] > 60 ? [p1 substringToIndex:60] : p1,
              [p2 length] > 60 ? [p2 substringToIndex:60] : p2, p4);

        NSArray *result = @[];
        if ([action isEqualToString:BJCStr("jsdebug")]) {
            WXLog(BJCStr("JS上报: %@"), p1);
        } else if ([action isEqualToString:BJCStr("sessions")]) {
            NSArray *sess = WXListSessions();
            NSMutableArray *out = [NSMutableArray array];
            for (NSDictionary *s in sess) {
                NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:s];
                m[BJCStr("firstChar")] = [m[BJCStr("name")] length] ? [m[BJCStr("name")] substringToIndex:1] : BJCStr("?");
                [out addObject:m];
            }
            result = out;
        } else if ([action isEqualToString:BJCStr("search_sessions")]) {
            result = WXSearchSessions(p1);
        } else if ([action isEqualToString:BJCStr("current_chat")]) {
            // 当前聊天会话信息（入口探测已写入 WXCurrentChatUsr）
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            NSString *usr = WXCurrentChatUsr;
            if (![usr length]) usr = WXCurrentChatUser();
            if (![usr length]) {
                d[BJCStr("ok")] = @NO;
                d[BJCStr("msg")] = BJCStr("请进入联系人或群内再开启");
            } else {
                d[BJCStr("ok")] = @YES;
                d[BJCStr("userName")] = usr;
                d[BJCStr("name")] = WXContactName(usr) ?: usr;
                // md5 → 找消息表
                NSString *md5 = WXMD5(usr);
                NSArray *dbs = WXFindMsgDBs();
                for (NSString *db in dbs) {
                    NSArray *t = WXQuery(db, [NSString stringWithFormat:BJCStr(
                        "SELECT name FROM sqlite_master WHERE type='table' AND name='Chat_%@'"), md5], 1);
                    if ([t count]) {
                        d[BJCStr("db")] = db;
                        d[BJCStr("table")] = [NSString stringWithFormat:BJCStr("Chat_%@"), md5];
                        break;
                    }
                }
                if (!d[BJCStr("table")]) d[BJCStr("ok")] = @NO;
            }
            result = @[d];
        } else if ([action isEqualToString:BJCStr("messages")]) {
            // p1=db p2=table p3=offset p4=limit；时间段过滤：p3 传 "offset|startTs|endTs"
            int offset = (int)p3.intValue;
            long long rStart = 0, rEnd = 0;
            if ([p3 rangeOfString:BJCStr("|")].location != NSNotFound) {
                NSArray *pp = [p3 componentsSeparatedByString:BJCStr("|")];
                offset = (int)[pp[0] intValue];
                if ([pp count] >= 3) {
                    rStart = [pp[1] longLongValue];
                    rEnd = [pp[2] longLongValue];
                }
            }
            if (rStart > 0 && rEnd > rStart) {
                result = WXFetchMessagesRangeDB(p1, p2, rStart, rEnd, offset, (int)p4);
            } else {
                result = WXFetchMessages(p1, p2, offset, (int)p4);
            }
        } else if ([action isEqualToString:BJCStr("search")]) {
            result = WXSearchMessages(p1, p2, p3, (int)p4);
        } else if ([action isEqualToString:BJCStr("stats")]) {
            result = WXStatsByDay(p1, p2, (int)p4 ?: 30);
        } else if ([action isEqualToString:BJCStr("stats_detail")]) {
            // p1=db p2=table p3=startTs p4=endTs
            result = WXStatsDetail(p1, p2, (long long)p3.longLongValue, p4);
        } else if ([action isEqualToString:BJCStr("group_rank")]) {
            // p1=db p2=table p3=startTs p4=endTs
            result = WXGroupRank(p1, p2, (long long)p3.longLongValue, p4);
        } else if ([action isEqualToString:BJCStr("copy_text")]) {
            // p1=要复制的文本
            WXCopyText(p1);
            result = @[@{BJCStr("ok"):@YES}];
        } else if ([action isEqualToString:BJCStr("ai_research")]) {
            // p1=db p2=table p3=name 或 name|startTs|endTs（统计弹窗 AI分析） p4=days(0=全部)
            long long now = (long long)[[NSDate date] timeIntervalSince1970];
            long long startTs = 0, endTs = now;
            NSString *name = p3;
            if (p4 > 0) startTs = now - p4 * 86400;
            // 自定义时间段：p3 = "name|startTs|endTs"
            NSArray *parts = [p3 componentsSeparatedByString:BJCStr("|")];
            if ([parts count] >= 3) {
                name = parts[0];
                startTs = [parts[1] longLongValue];
                endTs = [parts[2] longLongValue];
            }
            WXStartAIResearch(p1, p2, name, startTs, endTs, rid, @"");
            return;
        } else if ([action isEqualToString:BJCStr("ai_chat")]) {
            // 追问：p1=db p2=table p3=name p4=问题(需要自定义字段，用 p4 但 p4 是数字…改用 p3 通道)
            // 修正：问题放 p1，db/table 从 WXAIHistory 已有上下文，无需重传
            NSString *question = p1;
            long long now = (long long)[[NSDate date] timeIntervalSince1970];
            WXStartAIResearch(@"", @"", @"", 0, now, rid, question);
            return;
        } else if ([action isEqualToString:BJCStr("ai_setkey")]) {
            // p1=api key（兼容旧版：用户自定义 key 覆盖 DeepSeek 兜底）
            if ([p1 length]) {
                WXAIKey = p1;
                [[NSUserDefaults standardUserDefaults] setObject:p1 forKey:BJCStr("wxresearch_ai_key")];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
            // 返回 key 是否已配置（打码）
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[BJCStr("configured")] = @YES;
            out[BJCStr("masked")] = BJCStr("内置DeepSeek");
            result = @[out];
        } else if ([action isEqualToString:BJCStr("ai_getkey")]) {
            if (!WXAIKey) {
                WXAIKey = [[NSUserDefaults standardUserDefaults] stringForKey:BJCStr("wxresearch_ai_key")];
            }
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[BJCStr("configured")] = @YES;
            out[BJCStr("masked")] = BJCStr("内置DeepSeek");
            result = @[out];
        } else if ([action isEqualToString:BJCStr("ai_models")]) {
            // 返回内置模型信息（单一 DeepSeek）
            result = @[@{BJCStr("models"):@[
                @{@"name":BJCStr("DeepSeek"), @"model":BJCStr("deepseek-chat"), @"url":BJCStr("api.deepseek.com"), @"free":@NO, @"ok":@YES, @"desc":BJCStr("唯一AI模型（deepseek-chat）")}
            ], BJCStr("note"):BJCStr("DeepSeek deepseek-chat，按用量计费")}];
        } else if ([action isEqualToString:BJCStr("ai_test")]) {
            // 逐模型连通测试：最小请求 ping
            NSMutableArray *res = [NSMutableArray array];
            NSArray *tests = @[
                @{@"name":BJCStr("DeepSeek"), @"model":BJCStr("deepseek-chat"), @"url":BJCStr("https://api.deepseek.com/chat/completions"), @"key":BJCStr(WXDEEPSEEKKEY)}
            ];
            NSArray *ping = @[@{BJCStr("role"):BJCStr("user"), BJCStr("content"):BJCStr("hi")}];
            for (NSDictionary *t in tests) {
                NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:t];
                r[BJCStr("key")] = BJCStr("***");
                NSString *resp = WXAIRequestURL(t[BJCStr("url")], t[BJCStr("key")], t[BJCStr("model")], ping, 20);
                NSString *content = WXAIExtractContent(resp);
                if ([content length]) {
                    r[BJCStr("ok")] = @YES;
                    r[BJCStr("ms")] = BJCStr("正常");
                    r[BJCStr("reply")] = [content length] > 40 ? [content substringToIndex:40] : content;
                } else {
                    r[BJCStr("ok")] = @NO;
                    r[BJCStr("ms")] = BJCStr("失败");
                    r[BJCStr("reply")] = BJCStr("无响应（key无效/限流/网络）");
                }
                [res addObject:r];
            }
            result = @[@{BJCStr("results"):res}];
        } else if ([action isEqualToString:BJCStr("close")]) {
            UIViewController *top = WXTopVC();
            if (!top) return;
            [top dismissViewControllerAnimated:YES completion:nil];
            WXPageOpen = NO;
            return;
        }
        // 回调 JS（先递归清洗，防未配对 surrogate 炸 JSON）
        NSError *jerr = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:WXJSONSafe(result) options:0 error:&jerr];
        if (!json) {
            NSLog(BJCStr("[wxresearch] JSON FAIL: %@"), jerr);
            WXLog(BJCStr("JSON FAIL: %@"), jerr);
            return;
        }
        NSString *jsonStr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        if (!jsonStr) {
            NSLog(BJCStr("[wxresearch] JSON STRING FAIL"));
            WXLog(BJCStr("JSON STRING FAIL"));
            return;
        }
        NSLog(BJCStr("[wxresearch] reply rid=%lld jsonLen=%lu"), rid, (unsigned long)[jsonStr length]);
        WXLog(BJCStr("reply rid=%lld jsonLen=%lu"), rid, (unsigned long)[jsonStr length]);
        NSString *js = [NSString stringWithFormat:BJCStr("window.__cb(%lld, '%@');"), rid, WXJSEscape(jsonStr)];
        WKWebView *web = [msg webView];
        [web evaluateJavaScript:js completionHandler:nil];
    }
}

// ============ 页面 VC（动态类） ============
static void WXPageViewDidLoad(id self, SEL _cmd) {
    @autoreleasepool {
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        [v setBackgroundColor:[UIColor whiteColor]];
        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        [cfg.userContentController addScriptMessageHandler:WXMsgHandlerObj name:BJCStr("wxResearch")];
        WKWebView *web = [[WKWebView alloc] initWithFrame:v.bounds configuration:cfg];
        [web setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
        [v addSubview:web];
        NSString *html = WXPageHTML();
        NSLog(BJCStr("[wxresearch] page viewDidLoad htmlLen=%lu"), (unsigned long)[html length]);
        WXLog(BJCStr("page viewDidLoad htmlLen=%lu"), (unsigned long)[html length]);
        // baseURL 必须给值，否则 window.onerror 只报 "Script error."
        [web loadHTMLString:html baseURL:[NSURL URLWithString:BJCStr("https://wx.local/")]];
        // 2 秒后自检：页面是否渲染出内容（调试用）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [web evaluateJavaScript:BJCStr("(document.getElementById('content').innerHTML||'').length + '|' + (document.getElementById('content').innerHTML||'').substring(0,60)") completionHandler:^(id r, NSError *e) {
                NSLog(BJCStr("[wxresearch] selfcheck content=%@ err=%@"), r, e);
                WXLog(BJCStr("selfcheck content=%@ err=%@"), r, e);
            }];
        });
    }
}

// ============ 悬浮球 ============
// 拖动处理：UIPanGestureRecognizer → ballPan:
static void WXBallPan(id self, SEL _cmd, UIPanGestureRecognizer *gr) {
    @autoreleasepool {
        UIView *ball = [gr view];
        if (!ball) return;
        UIGestureRecognizerState st = [gr state];
        if (st == UIGestureRecognizerStateChanged) {
            CGPoint t = [gr translationInView:ball.superview];
            CGPoint c = ball.center;
            c.x += t.x;
            c.y += t.y;
            [ball setCenter:c];
            [gr setTranslation:CGPointZero inView:ball.superview];
        } else if (st == UIGestureRecognizerStateEnded || st == UIGestureRecognizerStateCancelled) {
            // 松手吸附屏幕边缘（最近的一侧），并限制在安全范围内
            UIView *sup = ball.superview;
            CGRect f = ball.frame;
            CGFloat w = sup ? sup.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
            CGFloat h = sup ? sup.bounds.size.height : [UIScreen mainScreen].bounds.size.height;
            CGFloat x = (f.origin.x + f.size.width / 2) < w / 2 ? 8 : w - f.size.width - 8;
            CGFloat y = f.origin.y;
            if (y < 88) y = 88;
            if (y > h - f.size.height - 48) y = h - f.size.height - 48;
            [ball setFrame:CGRectMake(x, y, f.size.width, f.size.height)];
        }
    }
}

// ============ 当前聊天会话探测 ============
// 递归遍历 VC/contact 对象的 ivars，找微信用户名（wxid_/xxx@chatroom/gh_ 特征）
static NSString *WXFindUsrNameIn(id obj, int depth) {
    if (!obj || depth <= 0) return nil;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([obj class], &count);
    NSString *fallback = nil;
    for (unsigned int i = 0; i < count; i++) {
        Ivar iv = ivars[i];
        NSString *n = [NSString stringWithUTF8String:ivar_getName(iv)];
        if ([n rangeOfString:BJCStr("UsrName")].location != NSNotFound ||
            [n rangeOfString:BJCStr("usrName")].location != NSNotFound) {
            id val = object_getIvar(obj, iv);
            if ([val isKindOfClass:[NSString class]] && [val length] > 3) {
                if ([val hasPrefix:BJCStr("wxid_")] || [val hasSuffix:BJCStr("@chatroom")] ||
                    [val hasPrefix:BJCStr("gh_")] || [val hasSuffix:BJCStr("@openim")] ||
                    [val hasPrefix:BJCStr("ghs_")]) {
                    free(ivars);
                    return val;
                }
                if (!fallback) fallback = val;
            }
            if ([val isKindOfClass:[NSObject class]] && ![val isKindOfClass:[NSString class]]) {
                NSString *sub = WXFindUsrNameIn(val, depth - 1);
                if (sub) { free(ivars); return sub; }
            }
        }
    }
    free(ivars);
    return fallback;
}

// 取当前最顶层 VC
static UIViewController *WXTopVC(void) {
    // iOS 13+ keyWindow 废弃，遍历 windows 找最上层
    UIWindow *win = nil;
    NSArray *wins = [UIApplication sharedApplication].windows;
    for (UIWindow *w in wins) {
        if (w.isKeyWindow) { win = w; break; }
    }
    if (!win && [wins count]) win = wins[0];
    if (!win) return nil;
    UIViewController *top = win.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]]) {
        top = [(UINavigationController *)top topViewController];
    }
    return top;
}

// 递归找 titleView / 视图层级中的 UILabel 文本（微信标题栏是自定义 titleView）
static NSString *WXFindLabelTextIn(id view, int depth) {
    if (!view || depth <= 0) return nil;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)view text];
        if ([t length]) return t;
    }
    if ([view isKindOfClass:[UIView class]]) {
        for (UIView *sub in [(UIView *)view subviews]) {
            NSString *t = WXFindLabelTextIn(sub, depth - 1);
            if ([t length]) return t;
        }
    }
    return nil;
}

// 当前聊天会话用户名：ivar 探测 → title 反查（WCDB_Contact 备注/微信号）
static NSString *WXCurrentChatUser(void) {
    UIViewController *top = WXTopVC();
    if (!top) return nil;
    NSString *u = WXFindUsrNameIn(top, 3);
    if ([u length]) return u;
    // 兜底：标题反查（微信标题在自定义 titleView 里，先试 navigationItem.titleView 再试 title）
    NSString *title = nil;
    if (top.navigationItem && top.navigationItem.titleView) {
        title = WXFindLabelTextIn(top.navigationItem.titleView, 4);
    }
    if (![title length]) title = top.title ?: (top.navigationItem ? top.navigationItem.title : nil);
    if (![title length]) {
        // 再试 navigationBar 顶层 item 的 titleView
        UINavigationBar *bar = [top.navigationController navigationBar];
        if (!bar && [top isKindOfClass:[UINavigationController class]]) {
            bar = [(UINavigationController *)top navigationBar];
        }
        if (bar) {
            UINavigationItem *ni = [bar topItem];
            if (ni.titleView) title = WXFindLabelTextIn(ni.titleView, 4);
            if (![title length]) title = ni.title;
        }
    }
    if (![title length]) return nil;
    NSString *dbDir = WXFindDBDir();
    if (!dbDir) return nil;
    NSString *wc = [dbDir stringByAppendingPathComponent:BJCStr("WCDB_Contact.sqlite")];
    NSString *escT = [title stringByReplacingOccurrencesOfString:BJCStr("'") withString:BJCStr("''")];
    NSArray *r = WXQuery(wc, [NSString stringWithFormat:BJCStr(
        "SELECT userName FROM Friend WHERE CAST(dbContactRemark AS TEXT) LIKE '%%%@%%' OR userName='%@' LIMIT 5"), escT, escT], 5);
    for (NSDictionary *d in r) {
        NSString *uu = d[BJCStr("userName")];
        if ([uu length] > 3) return uu;
    }
    return nil;
}

static void WXBallTapped(id self, SEL _cmd, id sender) {
    @autoreleasepool {
        UIWindow *win = nil;
        NSArray *wins = [UIApplication sharedApplication].windows;
        for (UIWindow *w in wins) { if (w.isKeyWindow) { win = w; break; } }
        if (!win && [wins count]) win = wins[0];
        if (!win) return;
        if (WXPageOpen) {
            UIViewController *top = WXTopVC();
            [top dismissViewControllerAnimated:YES completion:nil];
            WXPageOpen = NO;
            return;
        }
        // 非聊天页：直接打开研究页（页面内会提示进入联系人或群，也可浏览全部会话）
        WXCurrentChatUsr = WXCurrentChatUser();
        if (!WXPageVC) {
            Class vcCls = objc_allocateClassPair([UIViewController class], "WXResearchPageVC", 0);
            class_addMethod(vcCls, sel_registerName("viewDidLoad"), (IMP)WXPageViewDidLoad, "v@:");
            objc_registerClassPair(vcCls);
            WXPageVC = [[vcCls alloc] init];
        }
        UIViewController *top = WXTopVC();
        [top presentViewController:WXPageVC animated:YES completion:nil];
        WXPageOpen = YES;
    }
}

// ============ 安装悬浮球（延迟，避免微信启动早期崩溃） ============
static void WXInstallBall(void *ctx) {
    @autoreleasepool {
        if (!WXMsgHandlerObj) {
            Class hCls = objc_allocateClassPair([NSObject class], "WXMsgHandler", 0);
            class_addMethod(hCls, sel_registerName("userContentController:didReceiveScriptMessage:"),
                            (IMP)WXOnScriptMessage, "v@:@@");
            objc_registerClassPair(hCls);
            WXMsgHandlerObj = [[hCls alloc] init];
        }
        UIWindow *win = nil;
        NSArray *wins = [UIApplication sharedApplication].windows;
        for (UIWindow *w in wins) { if (w.isKeyWindow) { win = w; break; } }
        if (!win && [wins count]) win = wins[0];
        if (!win) return;
        if ([win viewWithTag:92001]) return;
        if (!WXBallTargetCls) {
            WXBallTargetCls = objc_allocateClassPair([NSObject class], "WXBallTarget", 0);
            class_addMethod(WXBallTargetCls, sel_registerName("ballTapped:"), (IMP)WXBallTapped, "v@:@");
            class_addMethod(WXBallTargetCls, sel_registerName("ballPan:"), (IMP)WXBallPan, "v@:@");
            objc_registerClassPair(WXBallTargetCls);
            WXBallTarget = [[WXBallTargetCls alloc] init];
        }
        UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
        [ball setTag:92001];
        CGRect b = win.bounds;
        [ball setFrame:CGRectMake(b.size.width - 76, b.size.height - 160, 56, 56)];
        [ball setBackgroundColor:[UIColor colorWithRed:0.03 green:0.76 blue:0.38 alpha:0.92]];
        [ball.layer setCornerRadius:28];
        [ball setTitle:BJCStr("研") forState:UIControlStateNormal];
        [[ball titleLabel] setFont:[UIFont boldSystemFontOfSize:20]];
        [ball addTarget:WXBallTarget action:@selector(ballTapped:) forControlEvents:UIControlEventTouchUpInside];
        // 拖拽
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:WXBallTarget action:@selector(ballPan:)];
        [pan setMaximumNumberOfTouches:1];
        [ball addGestureRecognizer:pan];
        [win addSubview:ball];
        WXBall = ball;
    }
}

// ============ 入口 ============
%ctor {
    NSLog(BJCStr("[wxresearch] dylib loaded (v1.1.0), installing ball"));
    WXLog(BJCStr("dylib loaded (v1.1.0)"));
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, (dispatch_function_t)WXInstallBall);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, (dispatch_function_t)WXInstallBall);
}
