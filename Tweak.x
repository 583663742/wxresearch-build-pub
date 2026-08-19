// 微信聊天研究 1.3.0 — pkc 式微信内插件（纯原生 UIKit 版）
// 注入微信进程(com.tencent.xin)，长按+号 → pkc菜单 → 统计/AI分析/聊天记录
// 原生 UIKit，无悬浮球，零读库直到点击
// AI 调用走用户自配 API（NSUserDefaults 存储 URL/Key/Model）
//
// arm64e 编译限制（全部遵守）：
//   - 新 ObjC 类用编译期 @interface/@implementation（pkc 同款写法，v1.2.3 起）
//   - 不用 %new（class_addMethod）
//   - 不用 block（dispatch_after_f + C 函数）
//   - @"..." 一律 BJCStr()
//   - objc_msgSend 一律走宏

#import <UIKit/UIKit.h>
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

// ========== 主题色 ==========
#define WX_THEME_COLOR [UIColor colorWithRed:52.0/255.0 green:152.0/255.0 blue:219.0/255.0 alpha:1.0]
#define WX_CARD_COLOR [UIColor whiteColor]
#define WX_BG_COLOR [UIColor colorWithRed:248.0/255.0 green:249.0/255.0 blue:250.0/255.0 alpha:1.0]
#define WX_BORDER_COLOR [UIColor colorWithRed:233.0/255.0 green:236.0/255.0 blue:239.0/255.0 alpha:1.0]
#define WX_TEXT_COLOR [UIColor colorWithRed:44.0/255.0 green:62.0/255.0 blue:80.0/255.0 alpha:1.0]
#define WX_SUBTEXT_COLOR [UIColor colorWithRed:127.0/255.0 green:140.0/255.0 blue:141.0/255.0 alpha:1.0]
#define WX_ME_BUBBLE [UIColor colorWithRed:214.0/255.0 green:234.0/255.0 blue:248.0/255.0 alpha:1.0]

// ========== 全局状态 ==========
static BOOL WXPageOpen = NO;
static UIViewController *WXPageVC = nil;          // 根 presenting VC（容器）
static UINavigationController *WXNav = nil;        // 主导航控制器
static NSString *WXCurrentChatUsr = nil;

// 全局 UI Target（用于所有 barButtonItem 点击）
static Class WXUITargetCls = nil;
static id WXUITarget = nil;

// v1.2.0: 联系人名缓存（减少 DB 查询）
static NSMutableDictionary *WXContactCache = nil;
// v1.2.0: 长按+号尝试次数（防反复扫描）
static int WXPlusBtnAttempts = 0;

// AI 研究状态
static NSMutableArray *WXAIHistory = nil;
static NSString *WXAIKey = nil;

// 当前会话上下文
static NSString *WXSessDB = nil;
static NSString *WXSessTable = nil;
static NSString *WXSessName = nil;
static NSString *WXSessUsr = nil;

// 当前时间过滤
typedef enum {
    WXRangeAll = 0,
    WXRangeToday = 1,
    WXRangeYesterday = 2,
    WXRange3Days = 3,
    WXRange7Days = 7,
    WXRange30Days = 30,
    WXRangeCustom = 999
} WXRangeType;
static WXRangeType WXCurRange = WXRangeAll;
static long long WXRangeStart = 0;
static long long WXRangeEnd = 0;

// ========== 前置声明 ==========
static NSString *WXAIExtractContent(NSString *html);
static NSString *WXCurrentChatUser(void);
static UIViewController *WXTopVC(void);

// ============ 文件日志 ============
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

// ============ MD5 ============
static NSString *WXMD5(NSString *input) {
    const char *cStr = [input UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [out appendFormat:BJCStr("%02x"), digest[i]];
    return out;
}

// ============ 数据库定位 ============
static NSString *WXFindDBDir(void) {
    NSString *doc = [NSHomeDirectory() stringByAppendingPathComponent:BJCStr("Documents")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *subs = [fm contentsOfDirectoryAtPath:doc error:nil];
    for (NSString *sub in subs) {
        if ([sub length] == 32) {
            NSString *db = [doc stringByAppendingPathComponent:[sub stringByAppendingPathComponent:BJCStr("DB")]];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:db isDirectory:&isDir] && isDir) {
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

// ============ 字符串清洗 ============
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
            [ms appendString:BJCStr("\uFFFD")];
        } else {
            [ms appendFormat:BJCStr("%C"), c];
        }
    }
    return ms;
}

static __attribute__((unused)) id WXJSONSafe(id obj) {
    if ([obj isKindOfClass:[NSString class]]) return WXCleanSurrogates(obj);
    if ([obj isKindOfClass:[NSData class]]) {
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

#define WXDEEPSEEKKEY "REPLACE_DEEPSEEK_KEY"

// ============ sqlite 查询 ============
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
                    const void *blob = sqlite3_column_blob(stmt, i);
                    int blen = sqlite3_column_bytes(stmt, i);
                    row[k] = blob ? [NSData dataWithBytes:blob length:(NSUInteger)blen] : [NSData data];
                }
                else {
                    const char *txt = (const char *)sqlite3_column_text(stmt, i);
                    if (txt) {
                        NSString *s = [NSString stringWithUTF8String:txt];
                        if (!s) {
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

// ============ protobuf 提取 field 1 ============
static NSString *WXProtoField1Str(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || [data length] < 3) return nil;
    const unsigned char *b = [data bytes];
    NSUInteger len = [data length];
    NSUInteger i = 0;
    while (i < len) {
        unsigned char tag = b[i++];
        if ((tag & 0x07) != 2) continue;
        uint64_t slen = 0; int shift = 0;
        while (i < len && (b[i] & 0x80)) {
            slen |= ((uint64_t)(b[i] & 0x7F)) << shift; shift += 7; i++;
        }
        if (i >= len) break;
        slen |= ((uint64_t)b[i]) << shift; i++;
        if (i + slen > len) break;
        if ((tag >> 3) == 1) {
            NSString *s = [[NSString alloc] initWithBytes:(b + i) length:(NSUInteger)slen encoding:NSUTF8StringEncoding];
            return WXCleanSurrogates(s ?: @"");
        }
        i += (NSUInteger)slen;
    }
    return nil;
}

// ============ 联系人名 ============
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
        if ([usrName length] > 12) return [NSString stringWithFormat:BJCStr("群[%@…]"), [usrName substringToIndex:8]];
        return usrName;
    }
    return usrName;
}

// ============ 消息查询（分页，最新在前→反转为正序）============
static NSArray *WXFetchMessages(NSString *db, NSString *table, int offset, int limit) {
    NSString *sql = [NSString stringWithFormat:BJCStr(
        "SELECT MesLocalID, CreateTime, Type, Message, Des FROM %@ ORDER BY MesLocalID DESC LIMIT %d OFFSET %d"),
        table, limit, offset];
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

// ============ 消息搜索 ============
static NSArray *WXSearchMessages(NSString *db, NSString *table, NSString *kw, int limit) {
    NSString *sql = [NSString stringWithFormat:BJCStr(
        "SELECT MesLocalID, CreateTime, Type, Message FROM %@ WHERE Message LIKE '%%%@%%' ORDER BY MesLocalID DESC LIMIT %d"),
        table, kw, limit];
    return WXQuery(db, sql, 0);
}

// ============ 时间段分页拉消息（聊天记录时间过滤）============
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

// ============ 按时间段提取消息（正序，AI 研究用）============
static NSArray *WXFetchMessagesRange(NSString *db, NSString *table, long long startTs, long long endTs, int limit) {
    NSString *sql;
    if (startTs > 0 && endTs > 0) {
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
        long long desVal = [m[BJCStr("Des")] longLongValue];
        m[BJCStr("isMe")] = @(desVal == 0);
        [out addObject:m];
    }
    return out;
}

// ============ 消息 → 文本（AI 研究用）============
static NSString *WXMessagesToText(NSArray *msgs, NSString *selfName, NSString *otherName) {
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *m in msgs) {
        long long ts = [m[BJCStr("CreateTime")] longLongValue];
        int type = (int)[m[BJCStr("Type")] longLongValue];
        NSString *msg = m[BJCStr("Message")];
        if (![msg isKindOfClass:[NSString class]]) {
            msg = msg ? [msg description] : @"";
        }
        NSString *who = [m[BJCStr("isMe")] boolValue] ? selfName : otherName;
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

// ============ AI API 调用 ============
static NSString *WXAIRequestURL(NSString *baseURL, NSString *apiKey, NSString *model,
                                NSArray *messages, int timeoutSec) {
    if (!apiKey || ![apiKey length]) return nil;
    // v1.3.0: temperature 从设置读取（默认 1.3，DeepSeek 官方推荐）
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    double temp = 1.3;
    NSString *tempStr = [ud stringForKey:BJCStr("wxresearch_ai_temp")];
    if (tempStr && [tempStr length]) {
        double t = [tempStr doubleValue];
        if (t >= 0 && t <= 2) temp = t;
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[BJCStr("model")] = model;
    payload[BJCStr("messages")] = messages;
    payload[BJCStr("temperature")] = @(temp);
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

static NSString *WXAIRequestChain(NSArray *messages, int timeoutSec) {
    // v1.2.0: 从 NSUserDefaults 读取用户配置的 AI 参数
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *url = [ud stringForKey:BJCStr("wxresearch_ai_url")];
    if (!url || ![url length]) url = BJCStr("https://api.deepseek.com/v1/chat/completions");
    NSString *key = [ud stringForKey:BJCStr("wxresearch_ai_key")] ?: BJCStr(WXDEEPSEEKKEY);
    NSString *model = [ud stringForKey:BJCStr("wxresearch_ai_model")];
    if (!model || ![model length]) model = BJCStr("deepseek-chat");
    return WXAIRequestURL(url, key, model, messages, timeoutSec);
}

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

// ============ AI 回调声明 ============
static void WXAICallbackNative(void *ctx);
static void WXAICBEmptyNative(void *ctx);

// ============ AI 研究主逻辑 ============
static void WXAIResearchMain(void *ctx) {
    @autoreleasepool {
        NSArray *params = (__bridge_transfer NSArray *)ctx;
        NSString *db = params[0];
        NSString *table = params[1];
        NSString *name = params[2];
        long long startTs = [params[3] longLongValue];
        long long endTs = [params[4] longLongValue];
        long long cbId = [params[5] longLongValue];
        NSString *userQuestion = [params count] > 6 ? params[6] : @"";
        
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
            dispatch_async_f(dispatch_get_main_queue(), (void *)CFBridgingRetain(cb), (dispatch_function_t)WXAICallbackNative);
            return;
        }
        
        NSArray *msgs = WXFetchMessagesRange(db, table, startTs, endTs, 2000);
        WXLog(BJCStr("AI fetch msgs=%lu start=%lld end=%lld"), (unsigned long)[msgs count], startTs, endTs);
        if (![msgs count]) {
            dispatch_async_f(dispatch_get_main_queue(), (void *)(long)cbId, (dispatch_function_t)WXAICBEmptyNative);
            return;
        }
        NSString *chatText = WXMessagesToText(msgs, BJCStr("我"), name);
        // v1.3.0: 超长截断保护（约 60000 字，防 token 爆炸）
        if ([chatText length] > 60000) {
            chatText = [chatText substringToIndex:60000];
            chatText = [chatText stringByAppendingString:BJCStr("\n\n……(记录过长已截断)")];
        }
        
        NSString *sysPrompt = [NSString stringWithFormat:BJCStr(
            "你是聊天记录研究助手。以下是「%@」的聊天记录（时间正序，格式：时间 发送者: 内容）。"
            "请从研究角度分析：1)主要话题和内容 2)关系状态与变化 3)重要事件/约定 4)值得注意的细节。"
            "用中文回复，条理清晰，不要编造记录里没有的内容。\n\n===聊天记录开始===\n%@\n===聊天记录结束==="),
            name, chatText];
        
        NSMutableArray *history = [NSMutableArray array];
        if ([userQuestion length] && [WXAIHistory count]) {
            [history addObjectsFromArray:WXAIHistory];
            [history addObject:@{BJCStr("role"): BJCStr("user"), BJCStr("content"): userQuestion}];
        } else {
            [history addObject:@{BJCStr("role"): BJCStr("system"), BJCStr("content"): sysPrompt}];
            NSString *sysShort = [NSString stringWithFormat:BJCStr(
                "以下是「%@」的聊天记录，已作为对话上下文。回答用户关于这段聊天的问题，用中文。"), name];
            WXAIHistory = [NSMutableArray arrayWithObject:@{BJCStr("role"): BJCStr("system"), BJCStr("content"): sysShort}];
            // v1.3.0: 若带了初始问题（没点开始分析直接追问），一并入请求
            if ([userQuestion length]) {
                [history addObject:@{BJCStr("role"): BJCStr("user"), BJCStr("content"): userQuestion}];
            }
        }
        
        NSString *respJson = WXAIRequestChain(history, 120);
        NSString *content = WXAIExtractContent(respJson);
        
        if (content) {
            [WXAIHistory addObject:@{BJCStr("role"): BJCStr("user"), BJCStr("content"): userQuestion ?: BJCStr("分析这段聊天")}];
            [WXAIHistory addObject:@{BJCStr("role"): BJCStr("assistant"), BJCStr("content"): content}];
        }
        
        NSMutableDictionary *cb = [NSMutableDictionary dictionary];
        cb[BJCStr("id")] = @(cbId);
        cb[BJCStr("ok")] = @(content != nil);
        cb[BJCStr("content")] = content ?: @"";
        if (!content) cb[BJCStr("error")] = respJson ?: BJCStr("API请求失败(检查Key/网络)");
        dispatch_async_f(dispatch_get_main_queue(), (void *)CFBridgingRetain(cb), (dispatch_function_t)WXAICallbackNative);
    }
}

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
    dispatch_async_f(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                     (void *)CFBridgingRetain(params), (dispatch_function_t)WXAIResearchMain);
}

// ============ 统计函数 ============
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

// ============ 剪贴板 ============
static void WXCopyText(NSString *text) {
    if (![text length]) return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    [pb setString:text];
}

// ========== 工具函数：时间格式化 ==========
static NSString *WXFmtTime(long long ts) {
    if (!ts) return @"";
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *dc = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:d];
    NSDateComponents *nc = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:now];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    if ([dc year] == [nc year] && [dc month] == [nc month] && [dc day] == [nc day]) {
        [fmt setDateFormat:BJCStr("HH:mm")];
    } else {
        [fmt setDateFormat:BJCStr("M/d")];
    }
    return [fmt stringFromDate:d];
}

static NSString *WXFmtDay(long long ts) {
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *dc = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:d];
    NSDateComponents *nc = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:now];
    NSDate *yest = [NSDate dateWithTimeIntervalSinceNow:-86400];
    NSDateComponents *yc = [cal components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:yest];
    if ([dc year] == [nc year] && [dc month] == [nc month] && [dc day] == [nc day]) return BJCStr("今天");
    if ([dc year] == [yc year] && [dc month] == [yc month] && [dc day] == [yc day]) return BJCStr("昨天");
    return [NSString stringWithFormat:BJCStr("%ld年%ld月%ld日"), (long)[dc year], (long)[dc month], (long)[dc day]];
}

static NSString *WXFmtMsg(int type, id rawMsg) {
    NSString *msg = [rawMsg isKindOfClass:[NSString class]] ? rawMsg : [rawMsg description];
    if (type == 1 || type == 10000) return msg;
    if (type == 3) return BJCStr("[图片]");
    if (type == 34) return BJCStr("[语音]");
    if (type == 43) return BJCStr("[视频]");
    if (type == 47) return BJCStr("[表情]");
    if (type == 49) {
        NSRange t = [msg rangeOfString:BJCStr("<title>")];
        NSRange te = [msg rangeOfString:BJCStr("</title>")];
        if (t.location != NSNotFound && te.location != NSNotFound && te.location > t.location) {
            NSString *tt = [msg substringWithRange:NSMakeRange(t.location + 7, te.location - t.location - 7)];
            return [NSString stringWithFormat:BJCStr("[链接] %@"), tt];
        }
        return BJCStr("[链接]");
    }
    if (type == 50) return BJCStr("[语音通话]");
    return [NSString stringWithFormat:BJCStr("[消息类型%d]"), type];
}

// ========== 头像颜色（稳定 hash）==========
static NSArray *WXAVColors(void) {
    static NSArray *cols = nil;
    // arm64e: 不用 dispatch_once block，改用静态 flag
    if (!cols) {
        cols = @[
            [UIColor colorWithRed:52.0/255 green:152.0/255 blue:219.0/255 alpha:1],
            [UIColor colorWithRed:16.0/255 green:174.0/255 blue:255.0/255 alpha:1],
            [UIColor colorWithRed:255.0/255 green:159.0/255 blue:10.0/255 alpha:1],
            [UIColor colorWithRed:255.0/255 green:69.0/255 blue:58.0/255 alpha:1],
            [UIColor colorWithRed:191.0/255 green:90.0/255 blue:242.0/255 alpha:1],
            [UIColor colorWithRed:94.0/255 green:92.0/255 blue:230.0/255 alpha:1],
            [UIColor colorWithRed:48.0/255 green:209.0/255 blue:88.0/255 alpha:1],
            [UIColor colorWithRed:0.0/255 green:199.0/255 blue:190.0/255 alpha:1],
            [UIColor colorWithRed:255.0/255 green:149.0/255 blue:0.0/255 alpha:1]
        ];
    }
    return cols;
}

static UIColor *WXAvColor(NSString *s) {
    NSArray *cols = WXAVColors();
    if (![s length]) return cols[0];
    NSUInteger h = 0;
    for (NSUInteger i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        h = (h * 31 + c) & 0x7FFFFFFF;
    }
    return [cols objectAtIndex:(h % [cols count])];
}

// ========== 时间范围计算 ==========
static void WXCalcRange(WXRangeType type, long long *start, long long *end,
                        long long customStart, long long customEnd) {
    long long now = (long long)[[NSDate date] timeIntervalSince1970];
    *end = now;
    switch (type) {
        case WXRangeAll:
            *start = 0; *end = 0; break;
        case WXRangeToday: {
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDate *d = [cal startOfDayForDate:[NSDate date]];
            *start = (long long)[d timeIntervalSince1970];
            *end = now;
            break;
        }
        case WXRangeYesterday: {
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDate *todayStart = [cal startOfDayForDate:[NSDate date]];
            *end = (long long)[todayStart timeIntervalSince1970];
            *start = *end - 86400;
            break;
        }
        case WXRange3Days:
        case WXRange7Days:
        case WXRange30Days:
            *start = now - (long long)type * 86400;
            break;
        case WXRangeCustom:
            *start = customStart;
            *end = customEnd;
            break;
    }
}

static NSString *WXRangeLabel(WXRangeType type) {
    switch (type) {
        case WXRangeAll: return BJCStr("全部");
        case WXRangeToday: return BJCStr("今天");
        case WXRangeYesterday: return BJCStr("昨天");
        case WXRange3Days: return BJCStr("近3天");
        case WXRange7Days: return BJCStr("近7天");
        case WXRange30Days: return BJCStr("近1月");
        case WXRangeCustom: return BJCStr("自定义");
    }
    return BJCStr("全部");
}

// ============ 当前聊天探测 ============
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

static UIViewController *WXTopVC(void) {
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

// v1.2.0: 首选 KVC 取当前会话名，降级用递归找 UILabel
static NSString *WXCurrentChatUser(void) {
    UIViewController *top = WXTopVC();
    if (!top) return nil;

    // 首选：KVC 直接从 VC 取 chatContact
    @try {
        id contact = [top valueForKey:BJCStr("chatContact")];
        if (contact) {
            // 尝试 m_nsUsrName（内部 ID，最可靠）
            NSString *u = [contact valueForKey:BJCStr("m_nsUsrName")];
            if ([u length] > 3) return u;
            // 群聊名
            NSString *n = [contact valueForKey:BJCStr("m_nsNickName")];
            if ([n length] > 0) {
                // KVC 拿到的是显示名，不是 usrName，但可以用于展示
                // usrName 需要后续从 DB 匹配（延迟到点击时）
            }
        }
    } @catch(NSException *e) {
        WXLog(BJCStr("KVC chatContact failed: %@"), e);
    }

    // 降级：递归找 UsrName ivar
    NSString *u = WXFindUsrNameIn(top, 3);
    if ([u length]) return u;

    // 最后降级：导航栏标题文本（仅用于展示，无法反查 usrName）
    // v1.2.0: 不再通过 DB 查询反查 usrName（违反零读库铁律）
    WXLog(BJCStr("WXCurrentChatUser: all methods failed, no usrName"));
    return nil;
}

// v1.2.0: 从当前 VC 取会话显示名（KVC + 降级导航栏标题）
static NSString *WXCurrentChatName(void) {
    UIViewController *top = WXTopVC();
    if (!top) return nil;
    @try {
        id contact = [top valueForKey:BJCStr("chatContact")];
        if (contact) {
            NSString *n = [contact valueForKey:BJCStr("m_nsNickName")];
            if ([n length]) return n;
        }
    } @catch(NSException *e) {}
    // 降级：导航栏标题
    NSString *title = nil;
    if (top.navigationItem && top.navigationItem.titleView) {
        title = WXFindLabelTextIn(top.navigationItem.titleView, 4);
    }
    if (![title length]) title = top.title ?: (top.navigationItem ? top.navigationItem.title : nil);
    return title;
}

// ========== 全局 VC 引用（动态类需要访问单例 VC）==========
static UIViewController *WXChatVCInstance = nil;
static UIViewController *WXStatsVCInstance = nil;
static UIViewController *WXAIVCInstance = nil;

// ========== 导航 Push/Pop 工具 ==========
static void WXNavPush(UIViewController *vc, BOOL animated) {
    if (WXNav && vc) {
        [WXNav pushViewController:vc animated:animated];
    }
}
static void WXNavPop(BOOL animated) {
    if (WXNav) {
        NSArray *vcs = [WXNav viewControllers];
        if ([vcs count] > 1) {
            [WXNav popViewControllerAnimated:animated];
        } else {
            // 栈底，关闭整个页面
            UIViewController *top = WXTopVC();
            if (top) [top dismissViewControllerAnimated:YES completion:nil];
            WXPageOpen = NO;
        }
    }
}

// =====================================================================

// =====================================================================
// v1.2.0: 以下开始：动态创建 UI 类 + 原生界面实现（pkc 式入口）
// 删除悬浮球、删除会话列表，改为：长按+号 → pkc菜单 + 设置页入口
// =====================================================================

// 前置声明（在定义之前被调用的函数）
static void WXShowPKCMenu(void);
static void WXPresentNext(void *ctx);
static void WXRegisterSettingsVC(void);
static void WXContainerViewDidLoad(id self, SEL _cmd);
// 全局变量前置（在定义之前使用）
static int WXNextVCMode = 0; // 0=stats, 1=AI, 2=chat, 3=settings
static Class WXSettingsVCClass = Nil;
// v1.2.0 fix: 前6个函数前向声明（class_addMethod IMP / dispatch_async_f 回调在定义前使用）
static void WXSettingsTFDone(id self, SEL _cmd, id sender);
static void WXSettingsSwitchChanged(id self, SEL _cmd, UISwitch *sw);
static void WXChatReloadUI(void *ctx);
static void WXStatsReload(void *ctx);
static void WXAIRefreshUI(void *ctx);

// ============ 通用 Target 动作（UIBarButtonItem 点击等）============
// 按钮 tag 约定：
//   101 = 返回（聊天页：回列表；AI页：回聊天）
//   102 = 搜索按钮（聊天页：toggle 搜索栏）
//   103 = 统计按钮（聊天页：弹出统计 sheet）
//   104 = AI 研究按钮（聊天页：进入 AI 页）
//   105 = 时间过滤按钮（聊天页：弹出时间 sheet）
//   201 = 统计：类型统计
//   202 = 统计：按天分布
//   203 = 统计：群消息排名
static void WXUIAct(id self, SEL _cmd, id sender) {
    @autoreleasepool {
        NSInteger tag = 0;
        if ([sender respondsToSelector:@selector(tag)]) tag = [sender tag];
        WXLog(BJCStr("WXUIAct tag=%ld"), (long)tag);
        if (tag == 101) { WXNavPop(YES); return; }
        [[NSNotificationCenter defaultCenter] postNotificationName:BJCStr("WXUIAction") object:sender];
    }
}
static UIBarButtonItem *WXMakeBarBtn(NSString *title, NSInteger tag) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:WX_THEME_COLOR forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [btn sizeToFit];
    btn.tag = tag;
    [btn addTarget:WXUITarget action:@selector(uiAct:) forControlEvents:UIControlEventTouchUpInside];
    UIBarButtonItem *bbi = [[UIBarButtonItem alloc] initWithCustomView:btn];
    return bbi;
}
static UIBarButtonItem *WXMakeBackBtn(void) { return WXMakeBarBtn(BJCStr("返回"), 101); }

// ============ 确保 WXUITarget 已创建（幂等）============
static void WXEnsureUITarget(void) {
    if (WXUITargetCls) return;
    WXUITargetCls = objc_allocateClassPair([NSObject class], "WXUITarget", 0);
    if (!WXUITargetCls) { WXLog(BJCStr("FATAL: alloc WXUITarget")); return; }
    class_addMethod(WXUITargetCls, sel_registerName("uiAct:"), (IMP)WXUIAct, "v@:@");
    objc_registerClassPair(WXUITargetCls);
    WXUITarget = [[WXUITargetCls alloc] init];
    WXLog(BJCStr("WXUITarget created"));
}

// ============ 当前会话上下文初始化（仅在点击菜单项时调用，非启动时）============
static BOOL WXSetupCurrentChatContext(void) {
    WXSessUsr = WXCurrentChatUser();
    WXSessName = WXCurrentChatName();
    if (!WXSessUsr) {
        WXLog(BJCStr("WXSetupCurrentChatContext: no usrName from KVC"));
        return NO;
    }
    WXSessTable = [NSString stringWithFormat:BJCStr("Chat_%@"), [WXMD5(WXSessUsr) lowercaseString]];
    // 在所有 DB 中查找包含此 table 的那个
    NSArray *dbs = WXFindMsgDBs();
    for (NSString *db in dbs) {
        NSArray *r = WXQuery(db, [NSString stringWithFormat:BJCStr("SELECT name FROM sqlite_master WHERE type='table' AND name='%@'"), WXSessTable], 1);
        if ([r count]) { WXSessDB = db; WXLog(BJCStr("ctx: db=%@ table=%@ usr=%@ name=%@"), db, WXSessTable, WXSessUsr, WXSessName); return YES; }
    }
    if ([dbs count]) { WXSessDB = dbs[0]; WXLog(BJCStr("ctx: fallback db=%@ table=%@"), WXSessDB, WXSessTable); return YES; }
    WXLog(BJCStr("ctx: no DB found"));
    return NO;
}

// =====================================================================
// 长按「+」号 → pkc 菜单
// =====================================================================

// =====================================================================
// v1.3.0: 入口复刻 pkc —— 长按表情按钮（主）+ 长按+号（兜底）
// pkc 实锤：hook BaseMsgContentViewController initToolView → 拿 expressionButton 挂长按
// =====================================================================

// 递归找 MMInputToolView（输入条容器）
static UIView *WXFindInputToolViewIn(UIView *view) {
    if (!view) return nil;
    NSString *cn = NSStringFromClass([view class]);
    if ([cn rangeOfString:BJCStr("MMInputToolView")].location != NSNotFound) return view;
    for (UIView *sub in view.subviews) {
        UIView *f = WXFindInputToolViewIn(sub);
        if (f) return f;
    }
    return nil;
}

// 递归收集按钮
static void WXCollectButtonsIn(UIView *view, NSMutableArray *arr) {
    if (!view) return;
    if ([view isKindOfClass:[UIButton class]]) [arr addObject:view];
    for (UIView *sub in view.subviews) WXCollectButtonsIn(sub, arr);
}

// 从输入条里找表情按钮（expressionButton，pkc 同款）
static UIButton *WXFindEmoticonButtonIn(UIView *view) {
    UIView *tool = WXFindInputToolViewIn(view);
    if (!tool) return nil;
    // 方式1：KVC 拿 expressionButton
    @try {
        id eb = [tool valueForKey:BJCStr("expressionButton")];
        if (eb && [eb isKindOfClass:[UIButton class]]) return (UIButton *)eb;
    } @catch(NSException *e) {}
    // 方式2：递归在输入条里找按钮——表情按钮是输入条中"最右倒数第二个"按钮（最右是+号）
    // 简化：找输入条里 x 坐标最大的两个按钮，取第二个
    NSMutableArray *btns = [NSMutableArray array];
    WXCollectButtonsIn(tool, btns);
    if ([btns count] < 2) return nil;
    // 按 x 排序取次大
    UIButton *max1 = nil, *max2 = nil;
    CGFloat x1 = -1, x2 = -1;
    for (UIButton *b in btns) {
        CGRect f = b.frame;
        CGFloat bx = f.origin.x;
        if (bx >= x1) { x2 = x1; max2 = max1; x1 = bx; max1 = b; }
        else if (bx >= x2) { x2 = bx; max2 = b; }
    }
    return max2;
}

// 递归找「+」号按钮：屏幕底部区域最右 UIButton（宽 24~90、窗口坐标 y > 屏高 50%）
// v1.3.0: 修复 frame 相对父视图坐标 bug → convertRect 转窗口坐标
static UIButton *WXFindPlusButtonIn(UIView *view) {
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win && [[UIApplication sharedApplication].windows count]) win = [UIApplication sharedApplication].windows[0];
    UIButton *candidate = nil;
    CGFloat maxX = 0;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)sub;
            CGRect f = win ? [btn.superview convertRect:btn.frame toView:win] : btn.frame;
            if (f.size.width >= 24 && f.size.width <= 90 && f.origin.y > screenH * 0.5) {
                if (f.origin.x >= maxX) { maxX = f.origin.x; candidate = btn; }
            }
        }
        UIButton *found = WXFindPlusButtonIn(sub);
        if (found) {
            CGRect f = win ? [found.superview convertRect:found.frame toView:win] : found.frame;
            if (f.origin.x >= maxX) { maxX = f.origin.x; candidate = found; }
        }
    }
    return candidate;
}

// 长按手势 target
static Class WXLongPressTargetCls = nil;
static id WXLongPressTarget = nil;

static void WXOnLongPressPlus(id self, SEL _cmd, UILongPressGestureRecognizer *gr) {
    @autoreleasepool {
        if ([gr state] != UIGestureRecognizerStateBegan) return;
        // 检查插件总开关（默认开）
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        BOOL enabled = [ud objectForKey:BJCStr("wxresearch_enabled")] ? [ud boolForKey:BJCStr("wxresearch_enabled")] : YES;
        if (!enabled) { WXLog(BJCStr("plugin disabled, skip")); return; }
        WXLog(BJCStr("long-press + detected, showing menu"));
        WXShowPKCMenu();
    }
}

// 幂等挂载长按手势：优先表情按钮（pkc 同款），兜底+号按钮；各自受设置开关控制
static void WXAttachLongPress(UIView *view) {
    if (WXPlusBtnAttempts >= 5) return; // 最多尝试 5 次
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL emojiOn = [ud objectForKey:BJCStr("wxresearch_entry_emoji")] ? [ud boolForKey:BJCStr("wxresearch_entry_emoji")] : YES;
    BOOL plusOn  = [ud objectForKey:BJCStr("wxresearch_entry_plus")] ? [ud boolForKey:BJCStr("wxresearch_entry_plus")] : YES;
    UIButton *target = nil;
    NSString *tgtName = nil;
    if (emojiOn) {
        target = WXFindEmoticonButtonIn(view);
        if (target) tgtName = BJCStr("emoticon");
    }
    if (!target && plusOn) {
        target = WXFindPlusButtonIn(view);
        if (target) tgtName = BJCStr("plus");
    }
    if (!target) { WXPlusBtnAttempts++; WXLog(BJCStr("entry button not found (attempt %d)"), WXPlusBtnAttempts); return; }
    // 检查是否已挂载
    for (UIGestureRecognizer *g in target.gestureRecognizers) {
        if ([g isKindOfClass:[UILongPressGestureRecognizer class]]) return; // 已挂载
    }
    if (!WXLongPressTargetCls) {
        WXLongPressTargetCls = objc_allocateClassPair([NSObject class], "WXLPTarget", 0);
        class_addMethod(WXLongPressTargetCls, sel_registerName("onLongPress:"), (IMP)WXOnLongPressPlus, "v@:@");
        objc_registerClassPair(WXLongPressTargetCls);
        WXLongPressTarget = [[WXLongPressTargetCls alloc] init];
    }
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:WXLongPressTarget action:@selector(onLongPress:)];
    [lp setMinimumPressDuration:0.5];
    [target addGestureRecognizer:lp];
    WXLog(BJCStr("long-press gesture attached to %@ button"), tgtName);
}

// swizzle BaseMsgContentViewController initToolView（pkc 同款：输入条构建后立刻挂长按）
static IMP WXOrigInitToolView = NULL;
static id WXHookedInitToolView(id self, SEL _cmd) {
    id r = nil;
    if (WXOrigInitToolView) r = ((id(*)(id, SEL))WXOrigInitToolView)(self, _cmd);
    @autoreleasepool {
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        WXAttachLongPress(v);
    }
    return r;
}

// swizzle BaseMsgContentViewController viewDidAppear:
static IMP WXOrigViewDidAppear = NULL;
static void WXHookedViewDidAppear(id self, SEL _cmd, BOOL animated) {
    // 调用原实现
    if (WXOrigViewDidAppear) ((void(*)(id, SEL, BOOL))WXOrigViewDidAppear)(self, _cmd, animated);
    // 挂长按手势（幂等）
    @autoreleasepool {
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        WXAttachLongPress(v);
    }
}

// =====================================================================
// pkc 式菜单 VC
// =====================================================================
static Class WXMenuVCClass = Nil;
static const int WXMenuRowCount = 5; // 统计/AI/记录/指南/设置

static void WXMenuVCViewDidLoad(id self, SEL _cmd) {
    @autoreleasepool {
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        [v setBackgroundColor:[UIColor colorWithRed:0 green:0 blue:0 alpha:0.4]];
        UITableView *tv = [[UITableView alloc] initWithFrame:CGRectMake(0, v.bounds.size.height, v.bounds.size.width, 280) style:UITableViewStyleGrouped];
        [tv setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin];
        [tv setDelegate:(id)self];
        [tv setDataSource:(id)self];
        [tv setBackgroundColor:WX_BG_COLOR];
        [v addSubview:tv];
        // 点击背景 dismiss
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(menuBgTapped:)];
        [tap setCancelsTouchesInView:NO];
        [v addGestureRecognizer:tap];
        // 动画弹出（arm64e 不用 block，用 CATransition 代替）
        CATransition *anim = [CATransition animation];
        [anim setType:kCATransitionReveal];
        [anim setDuration:0.3];
        [tv.layer addAnimation:anim forKey:BJCStr("slide")];
        CGRect f = tv.frame;
        f.origin.y = v.bounds.size.height - f.size.height;
        [tv setFrame:f];
    }
}
static void WXMenuBgTapped(id self, SEL _cmd, id sender) {
    @autoreleasepool {
        UIViewController *thisVC = (UIViewController *)self;
        [thisVC dismissViewControllerAnimated:YES completion:nil];
    }
}
static NSInteger WXMenuVCSections(id self, SEL _cmd, UITableView *tv) {
    return 3; // 0=会话名, 1=功能, 2=设置
}
static NSInteger WXMenuVCRows(id self, SEL _cmd, UITableView *tv, NSInteger sec) {
    if (sec == 0) return 1;
    if (sec == 1) return WXMenuRowCount - 1; // 4: 统计/AI/记录/指南
    if (sec == 2) return 1; // 设置
    return 0;
}
static NSString *WXMenuVCTitle(id self, SEL _cmd, UITableView *tv, NSInteger sec) {
    if (sec == 0) return WXSessName ?: BJCStr("当前会话");
    if (sec == 2) return BJCStr("工具");
    return @"";
}
static UITableViewCell *WXMenuVCCell(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    @autoreleasepool {
        NSInteger sec = [ip section], row = [ip row];
        NSString *title = nil;
        if (sec == 0) title = WXSessName ?: BJCStr("（未知会话）");
        else if (sec == 1) {
            const char *items[] = {"📊 统计", "🤖 AI 分析", "💬 聊天记录", "📖 使用指南"};
            title = BJCStr(items[row]);
        } else if (sec == 2) title = BJCStr("⚙️ 设置");
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:BJCStr("menuCell")];
        [[cell textLabel] setText:title];
        [[cell textLabel] setFont:[UIFont systemFontOfSize:16]];
        if (sec == 0) {
            [[cell textLabel] setTextColor:WX_SUBTEXT_COLOR];
            [[cell textLabel] setTextAlignment:NSTextAlignmentCenter];
            [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
        }
        return cell;
    }
}
static void WXMenuVCSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    @autoreleasepool {
        [tv deselectRowAtIndexPath:ip animated:YES];
        NSInteger sec = [ip section], row = [ip row];
        UIViewController *thisVC = (UIViewController *)self;
        if (sec == 1) {
            // 0=统计, 1=AI, 2=聊天记录, 3=使用指南
            WXNextVCMode = row; // 0=stats, 1=AI, 2=chat
            // 先设置当前会话上下文（此处才读库，符合铁律）
            if (row <= 2) {
                if (!WXSetupCurrentChatContext()) {
                    // 无法获取会话上下文，提示
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:BJCStr("提示") message:BJCStr("无法获取当前会话信息，请确保在聊天界面内长按。") preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:BJCStr("确定") style:UIAlertActionStyleDefault handler:nil]];
                    [thisVC presentViewController:alert animated:YES completion:nil];
                    return;
                }
            }
            // dismiss 菜单 → 延迟 present
            [thisVC dismissViewControllerAnimated:YES completion:nil];
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), NULL, (dispatch_function_t)WXPresentNext);
        } else if (sec == 2) {
            // 设置
            WXNextVCMode = 3;
            [thisVC dismissViewControllerAnimated:YES completion:nil];
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), NULL, (dispatch_function_t)WXPresentNext);
        }
    }
}

static void WXRegisterMenuVC(void) {
    if (WXMenuVCClass) return;
    WXMenuVCClass = objc_allocateClassPair([UIViewController class], "WXMenuVC", 0);
    class_addMethod(WXMenuVCClass, sel_registerName("viewDidLoad"), (IMP)WXMenuVCViewDidLoad, "v@:");
    class_addMethod(WXMenuVCClass, sel_registerName("menuBgTapped:"), (IMP)WXMenuBgTapped, "v@:@");
    class_addMethod(WXMenuVCClass, sel_registerName("numberOfSectionsInTableView:"), (IMP)WXMenuVCSections, "l@:@");
    class_addMethod(WXMenuVCClass, sel_registerName("tableView:numberOfRowsInSection:"), (IMP)WXMenuVCRows, "l@:@@:l");
    class_addMethod(WXMenuVCClass, sel_registerName("tableView:titleForHeaderInSection:"), (IMP)WXMenuVCTitle, "@@:@@:l");
    class_addMethod(WXMenuVCClass, sel_registerName("tableView:cellForRowAtIndexPath:"), (IMP)WXMenuVCCell, "@@:@@:@");
    class_addMethod(WXMenuVCClass, sel_registerName("tableView:didSelectRowAtIndexPath:"), (IMP)WXMenuVCSelect, "v@:@@:@");
    objc_registerClassPair(WXMenuVCClass);
}

// 弹出 pkc 菜单
static void WXShowPKCMenu(void) {
    @autoreleasepool {
        WXEnsureUITarget();
        WXRegisterMenuVC();
        // 获取当前会话名（KVC，不读库）
        WXSessName = WXCurrentChatName();
        WXSessUsr = WXCurrentChatUser();
        UIViewController *menuVC = [[WXMenuVCClass alloc] init];
        [menuVC setModalPresentationStyle:UIModalPresentationOverCurrentContext];
        [menuVC setModalTransitionStyle:UIModalTransitionStyleCrossDissolve];
        UIViewController *top = WXTopVC();
        [top presentViewController:menuVC animated:YES completion:nil];
        WXPageOpen = YES;
        WXLog(BJCStr("pkc menu shown, sess=%@"), WXSessName);
    }
}

// =====================================================================
// dismiss → present 链（arm64e 无 block，用 dispatch_after_f + C 函数）
// =====================================================================

static void WXPresentNext(void *ctx) {
    @autoreleasepool {
        if (WXNextVCMode == 3) {
            // 设置页
            WXEnsureUITarget();
            WXRegisterSettingsVC();
            UIViewController *setVC = [[WXSettingsVCClass alloc] init];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:setVC];
            [nav.navigationBar setBarTintColor:WX_THEME_COLOR];
            UIViewController *top = WXTopVC();
            [top presentViewController:nav animated:YES completion:nil];
            return;
        }
        // 统计/AI/聊天记录 → 容器 VC
        WXEnsureUITarget();
        static Class containerCls = Nil;
        if (!containerCls) {
            containerCls = objc_allocateClassPair([UIViewController class], "WXContainerVC", 0);
            class_addMethod(containerCls, sel_registerName("viewDidLoad"), (IMP)WXContainerViewDidLoad, "v@:");
            objc_registerClassPair(containerCls);
        }
        WXPageVC = [[containerCls alloc] init];
        UIViewController *top = WXTopVC();
        [top presentViewController:WXPageVC animated:YES completion:nil];
        WXPageOpen = YES;
    }
}

// =====================================================================
// 容器 VC（根据 WXNextVCMode 创建对应 root VC）
// =====================================================================
static void WXContainerViewDidLoad(id self, SEL _cmd) {
    @autoreleasepool {
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        [v setBackgroundColor:WX_BG_COLOR];
        WXEnsureUITarget();
        // 根据 mode 注册并创建 root VC
        UIViewController *rootVC = nil;
        if (WXNextVCMode == 0) {
            // 统计
            extern void WXRegisterStatsVC(void);
            extern Class WXStatsVCClass;
            WXRegisterStatsVC();
            if (!WXStatsVCInstance && WXStatsVCClass) WXStatsVCInstance = [[WXStatsVCClass alloc] init];
            rootVC = WXStatsVCInstance;
        } else if (WXNextVCMode == 1) {
            // AI
            extern void WXRegisterAIVC(void);
            extern Class WXAIVCClass;
            WXRegisterAIVC();
            if (!WXAIVCInstance && WXAIVCClass) WXAIVCInstance = [[WXAIVCClass alloc] init];
            rootVC = WXAIVCInstance;
        } else {
            // 聊天记录
            extern void WXRegisterChatVC(void);
            extern Class WXChatVCClass;
            WXRegisterChatVC();
            if (!WXChatVCInstance && WXChatVCClass) WXChatVCInstance = [[WXChatVCClass alloc] init];
            rootVC = WXChatVCInstance;
        }
        if (!rootVC) { WXLog(BJCStr("FATAL: rootVC is nil for mode %d"), WXNextVCMode); return; }
        if (!WXNav) {
            WXNav = [[UINavigationController alloc] initWithRootViewController:rootVC];
        } else {
            [WXNav setViewControllers:@[rootVC] animated:NO];
        }
        [WXNav setNavigationBarHidden:NO];
        if ([WXNav.navigationBar respondsToSelector:@selector(setBarTintColor:)]) {
            WXNav.navigationBar.barTintColor = [UIColor colorWithRed:1 green:1 blue:1 alpha:0.92];
            WXNav.navigationBar.translucent = YES;
            WXNav.navigationBar.tintColor = WX_THEME_COLOR;
        }
        WXNav.view.frame = v.bounds;
        WXNav.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [v addSubview:WXNav.view];
    }
}

// =====================================================================
// 设置 VC（原生 UITableView：AI 配置 + 总开关 + 版本号）
// =====================================================================
// （WXSettingsVCClass 定义见文件顶部前置声明区）
static Class WXSettingsTargetCls = nil;
static id WXSettingsTarget = nil;
static UITextField *WXSetURLField = nil;
static UITextField *WXSetKeyField = nil;
static UITextField *WXSetModelField = nil;
static UITextField *WXSetTempField = nil; // v1.3.0: AI 温度
static UISwitch *WXSetEnabledSwitch = nil;
static UISwitch *WXSetEmojiSwitch = nil;   // v1.3.0: 长按表情入口
static UISwitch *WXSetPlusSwitch = nil;    // v1.3.0: 长按+号入口
static UISwitch *WXSetRevokeSwitch = nil;  // v1.3.0: 防撤回记录
// v1.3.0: 当前设置 VC 实例（返回按钮 pop/dismiss 判断用）
static UIViewController *WXCurSettingsVC = nil;

static void WXSettingsVCViewDidLoad(id self, SEL _cmd) {
    @autoreleasepool {
        UIViewController *vc = (UIViewController *)self;
        WXCurSettingsVC = vc; // v1.3.0: 记录实例
        [vc setTitle:BJCStr("聊天研究")];
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        [v setBackgroundColor:WX_BG_COLOR];
        UITableView *tv = [[UITableView alloc] initWithFrame:v.bounds style:UITableViewStyleGrouped];
        [tv setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
        [tv setDelegate:(id)self];
        [tv setDataSource:(id)self];
        [v addSubview:tv];
        // target
        if (!WXSettingsTargetCls) {
            WXSettingsTargetCls = objc_allocateClassPair([NSObject class], "WXSetTarget", 0);
            class_addMethod(WXSettingsTargetCls, sel_registerName("tfDone:"), (IMP)WXSettingsTFDone, "v@:@");
            class_addMethod(WXSettingsTargetCls, sel_registerName("backTapped:"), (IMP)WXSettingsBackTapped, "v@:@");
            class_addMethod(WXSettingsTargetCls, sel_registerName("switchChanged:"), (IMP)WXSettingsSwitchChanged, "v@:@");
            objc_registerClassPair(WXSettingsTargetCls);
            WXSettingsTarget = [[WXSettingsTargetCls alloc] init];
        }
        // 导航栏返回按钮（v1.3.0: 改 backTapped，修复退出黑屏）
        vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:BJCStr("返回") style:UIBarButtonItemStylePlain target:WXSettingsTarget action:@selector(backTapped:)];
    }
}
static void WXSettingsTFDone(id self, SEL _cmd, id sender) {
    @autoreleasepool {
        // 保存 UITextField 值到 NSUserDefaults
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if (WXSetURLField) [ud setObject:[WXSetURLField text] forKey:BJCStr("wxresearch_ai_url")];
        if (WXSetKeyField) [ud setObject:[WXSetKeyField text] forKey:BJCStr("wxresearch_ai_key")];
        if (WXSetModelField) [ud setObject:[WXSetModelField text] forKey:BJCStr("wxresearch_ai_model")];
        if (WXSetTempField) [ud setObject:[WXSetTempField text] forKey:BJCStr("wxresearch_ai_temp")];
        [ud synchronize];
        WXLog(BJCStr("settings saved"));
    }
}
// v1.3.0: 返回按钮：push 进来 → pop；present 进来 → dismiss（修复退出设置页黑屏）
static void WXSettingsBackTapped(id self, SEL _cmd, id sender) {
    @autoreleasepool {
        // 先保存
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if (WXSetURLField) [ud setObject:[WXSetURLField text] forKey:BJCStr("wxresearch_ai_url")];
        if (WXSetKeyField) [ud setObject:[WXSetKeyField text] forKey:BJCStr("wxresearch_ai_key")];
        if (WXSetModelField) [ud setObject:[WXSetModelField text] forKey:BJCStr("wxresearch_ai_model")];
        if (WXSetTempField) [ud setObject:[WXSetTempField text] forKey:BJCStr("wxresearch_ai_temp")];
        [ud synchronize];
        WXLog(BJCStr("settings back tapped"));
        UIViewController *vc = WXCurSettingsVC;
        if (!vc) vc = WXTopVC();
        UINavigationController *nav = nil;
        if ([vc respondsToSelector:@selector(navigationController)])
            nav = [vc navigationController];
        if (nav && [[nav viewControllers] count] > 1) {
            [nav popViewControllerAnimated:YES]; // push 进来 → pop
        } else {
            [vc dismissViewControllerAnimated:YES completion:nil]; // present 进来 → dismiss
        }
    }
}
// v1.3.0: 开关变化：按 tag 区分存储（100=总开关 101=长按表情 102=长按+号 103=防撤回）
static void WXSettingsSwitchChanged(id self, SEL _cmd, UISwitch *sw) {
    @autoreleasepool {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSInteger tag = [sw tag];
        if (tag == 101) {
            [ud setBool:[sw isOn] forKey:BJCStr("wxresearch_entry_emoji")];
            WXLog(BJCStr("entry emoji=%d"), [sw isOn] ? 1 : 0);
        } else if (tag == 102) {
            [ud setBool:[sw isOn] forKey:BJCStr("wxresearch_entry_plus")];
            WXLog(BJCStr("entry plus=%d"), [sw isOn] ? 1 : 0);
        } else if (tag == 103) {
            [ud setBool:[sw isOn] forKey:BJCStr("wxresearch_revoke")];
            WXLog(BJCStr("revoke record=%d"), [sw isOn] ? 1 : 0);
        } else {
            [ud setBool:[sw isOn] forKey:BJCStr("wxresearch_enabled")];
            WXLog(BJCStr("plugin enabled=%d"), [sw isOn] ? 1 : 0);
        }
        [ud synchronize];
    }
}
static NSInteger WXSettingsVCSections(id self, SEL _cmd, UITableView *tv) { return 3; }
static NSInteger WXSettingsVCRows(id self, SEL _cmd, UITableView *tv, NSInteger sec) {
    if (sec == 0) return 4; // URL/Key/Model/温度
    if (sec == 1) return 4; // 总开关/长按表情/长按+号/防撤回
    if (sec == 2) return 1; // 版本号
    return 0;
}
static NSString *WXSettingsVCTitle(id self, SEL _cmd, UITableView *tv, NSInteger sec) {
    if (sec == 0) return BJCStr("AI 配置");
    if (sec == 1) return BJCStr("通用");
    if (sec == 2) return BJCStr("关于");
    return @"";
}
static UITableViewCell *WXSettingsVCCell(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    @autoreleasepool {
        NSInteger sec = [ip section], row = [ip row];
        if (sec == 0) {
            const char *labels[] = {"接口地址", "API Key", "模型名", "AI 温度(0-2)"};
            const char *keys[] = {"wxresearch_ai_url", "wxresearch_ai_key", "wxresearch_ai_model", "wxresearch_ai_temp"};
            const char *defaults[] = {"https://api.deepseek.com/v1/chat/completions", "", "deepseek-chat", "1.3"};
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:BJCStr("setCell")];
            [[cell textLabel] setText:BJCStr(labels[row])];
            // UITextField
            UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(110, 8, cell.contentView.bounds.size.width - 120, 28)];
            [tf setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
            [tf setFont:[UIFont systemFontOfSize:14]];
            [tf setClearButtonMode:UITextFieldViewModeWhileEditing];
            [tf setReturnKeyType:UIReturnKeyDone];
            [tf setKeyboardType:(row == 3 ? UIKeyboardTypeDecimalPad : UIKeyboardTypeDefault)];
            [tf addTarget:WXSettingsTarget action:@selector(tfDone:) forControlEvents:UIControlEventEditingDidEndOnExit];
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            NSString *val = [ud objectForKey:BJCStr(keys[row])];
            [tf setText:val ?: BJCStr(defaults[row])];
            if (row == 0) WXSetURLField = tf;
            else if (row == 1) WXSetKeyField = tf;
            else if (row == 2) WXSetModelField = tf;
            else WXSetTempField = tf;
            [cell.contentView addSubview:tf];
            return cell;
        } else if (sec == 1) {
            // 通用区：总开关/长按表情/长按+号/防撤回
            const char *labels[] = {"启用插件", "长按表情按钮", "长按+号按钮", "防撤回记录"};
            const char *keys[] = {"wxresearch_enabled", "wxresearch_entry_emoji", "wxresearch_entry_plus", "wxresearch_revoke"};
            NSInteger tags[] = {100, 101, 102, 103};
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:BJCStr("setCell")];
            [[cell textLabel] setText:BJCStr(labels[row])];
            UISwitch *sw = [[UISwitch alloc] init];
            [sw setTag:tags[row]];
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            BOOL on = YES;
            if ([ud objectForKey:BJCStr(keys[row])]) on = [ud boolForKey:BJCStr(keys[row])];
            [sw setOn:on];
            [sw addTarget:WXSettingsTarget action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            if (row == 0) WXSetEnabledSwitch = sw;
            else if (row == 1) WXSetEmojiSwitch = sw;
            else if (row == 2) WXSetPlusSwitch = sw;
            else WXSetRevokeSwitch = sw;
            [cell setAccessoryView:sw];
            return cell;
        } else {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:BJCStr("setCell")];
            [[cell textLabel] setText:BJCStr("版本")];
            [[cell detailTextLabel] setText:BJCStr("v1.3.0")];
            [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
            return cell;
        }
    }
}
static void WXSettingsVCSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    @autoreleasepool { [tv deselectRowAtIndexPath:ip animated:YES]; }
}
// ========== 编译期真实类（pkc 同款写法，替代 objc_allocateClassPair 动态类）==========
// v1.2.3: 动态类缺 ivar/property 元数据，微信 push 插件 controller 时 KVC 等操作会抛
// NSUnknownKeyException 闪退；编译期类与 pkc/WeChatPluginHook 完全一致，元数据完整。
// 方法体直接复用上方 C 函数 IMP（最小改动）。
@interface WXSettingsVC : UIViewController
@end
@implementation WXSettingsVC
- (void)viewDidLoad {
    @autoreleasepool {
        WXLog(BJCStr("[settings] viewDidLoad entered, self=%p"), self);
        WXSettingsVCViewDidLoad(self, _cmd);
        WXLog(BJCStr("[settings] viewDidLoad done"));
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return WXSettingsVCSections(self, _cmd, tv); }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec { return WXSettingsVCRows(self, _cmd, tv, sec); }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)sec { return WXSettingsVCTitle(self, _cmd, tv, sec); }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip { return WXSettingsVCCell(self, _cmd, tv, ip); }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { WXSettingsVCSelect(self, _cmd, tv, ip); }
@end
static void WXRegisterSettingsVC(void) {
    if (WXSettingsVCClass) return;
    WXSettingsVCClass = [WXSettingsVC class];
    WXLog(BJCStr("[settings] WXSettingsVC class ready: %@"), NSStringFromClass(WXSettingsVCClass));
}

// =====================================================================
// %ctor（v1.2.0：注册 hook，无悬浮球）
// =====================================================================
// v1.2.3: 崩溃捕获 —— uncaught exception 写 /tmp/wxr_crash.log + wxresearch.log
static void WXUncaughtExceptionHandler(NSException *exception) {
    @autoreleasepool {
        NSString *desc = [NSString stringWithFormat:@"UNCAUGHT EXCEPTION: %@\nReason: %@\nStack:\n%@",
                          [exception name], [exception reason],
                          [[exception callStackSymbols] componentsJoinedByString:@"\n"]];
        [desc writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:BJCStr("wxr_crash.log")]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];
        WXLog(desc);
    }
}
%ctor {
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(&WXUncaughtExceptionHandler);
        NSLog(BJCStr("[wxresearch] dylib loaded v1.3.0 (pkc entry)"));
        // 初始化联系人缓存
        WXContactCache = [NSMutableDictionary dictionary];
        // 初始化 AI 历史
        WXAIHistory = [NSMutableArray array];

        // Hook BaseMsgContentViewController viewDidAppear:
        Class chatVC = objc_getClass("BaseMsgContentViewController");
        if (chatVC) {
            Method m = class_getInstanceMethod(chatVC, sel_registerName("viewDidAppear:"));
            if (m) {
                WXOrigViewDidAppear = method_getImplementation(m);
                method_setImplementation(m, (IMP)WXHookedViewDidAppear);
                NSLog(BJCStr("[wxresearch] BaseMsgContentViewController viewDidAppear hooked"));
            } else {
                NSLog(BJCStr("[wxresearch] WARN: viewDidAppear: not found on BaseMsgContentViewController"));
            }
            // v1.3.0: 也 hook initToolView（pkc 同款，输入条构建后立刻挂长按）
            Method mi = class_getInstanceMethod(chatVC, sel_registerName("initToolView"));
            if (mi) {
                WXOrigInitToolView = method_getImplementation(mi);
                method_setImplementation(mi, (IMP)WXHookedInitToolView);
                NSLog(BJCStr("[wxresearch] BaseMsgContentViewController initToolView hooked"));
            } else {
                NSLog(BJCStr("[wxresearch] WARN: initToolView not found on BaseMsgContentViewController"));
            }
        } else {
            NSLog(BJCStr("[wxresearch] WARN: BaseMsgContentViewController not found"));
        }

        // 用 WCPluginsMgr 注册插件入口（微信插件标准注册机制，参考 WeChatPluginHook class-dump）
        // registerControllerWithTitle:version:controller: → 插件页自动出现入口
        Class mgrCls = objc_getClass("WCPluginsMgr");
        if (mgrCls) {
            WXRegisterSettingsVC();
            id mgr = ((id(*)(id, SEL))objc_msgSend)((id)mgrCls, sel_registerName("sharedInstance"));
            if (mgr) {
                NSString *clsName = NSStringFromClass(WXSettingsVCClass);
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(mgr, sel_registerName("registerControllerWithTitle:version:controller:"),
                    BJCStr("聊天研究"), BJCStr("v1.3.0"), clsName);
                WXLog(BJCStr("WCPluginsMgr registered entry: 聊天研究 v1.3.0 -> %@"), clsName);
                NSLog(BJCStr("[wxresearch] WCPluginsMgr registered: 聊天研究 v1.3.0 -> %@"), clsName);
            } else {
                WXLog(BJCStr("WARN: WCPluginsMgr sharedInstance returned nil"));
            }
        } else {
            WXLog(BJCStr("WARN: WCPluginsMgr class not found"));
        }

        WXLog(BJCStr("ctor done, all hooks registered"));
        NSLog(BJCStr("[wxresearch] all hooks registered, waiting for user interaction"));
    }
}
// ============ 第1部分结束 ============

// 第2部分将实现：聊天记录VC(WXChatVC)、统计VC(WXStatsVC)、AI研究VC(WXAIVC)、
// 时间/统计 Sheet 弹窗、AI回调 Native 实现、WXRegisterChatVC 导出、
// 继续往 WXUITargetCls 添加新动作方法（搜索/统计/AI/时间过滤按钮动作）
// ============================================================
// 微信聊天研究 1.2.0 纯原生 UIKit 版 — 第2部分
// 与第1部分拼接为完整 Tweak.x
// ============================================================

// ========== 聊天 VC 数据 ==========
static NSMutableArray *WXChatMsgs = nil;       // 已加载消息，正序
static NSMutableArray *WXChatDisplay = nil;    // 渲染用：@[day分隔, msg, day分隔, msg...]
static int WXChatOffset = 0;
static BOOL WXChatLoading = NO;
static BOOL WXChatAllLoaded = NO;
static BOOL WXChatSearchMode = NO;
static NSMutableArray *WXChatSearchResult = nil;

// ========== Sheet 管理（底部弹出菜单用）==========
static UIView *WXSheetMask = nil;
static UIView *WXSheetContent = nil;

static void WXSheetDismiss(id sender) {
    @autoreleasepool {
        if (WXSheetMask) {
            // arm64e: 不用 block，直接移除（动画可省略）
            WXSheetMask.alpha = 0;
            if (WXSheetContent) {
                CGRect f = WXSheetContent.frame;
                f.origin.y = WXSheetMask.bounds.size.height;
                WXSheetContent.frame = f;
            }
            [WXSheetMask removeFromSuperview];
            WXSheetMask = nil;
            WXSheetContent = nil;
        }
    }
}

static UIView *WXSheetShow(UIView *contentView, CGFloat contentHeight) {
    @autoreleasepool {
        // 先关旧的
        if (WXSheetMask) { [WXSheetMask removeFromSuperview]; WXSheetMask = nil; WXSheetContent = nil; }
        
        UIWindow *win = nil;
        NSArray *wins = [UIApplication sharedApplication].windows;
        for (UIWindow *w in wins) { if (w.isKeyWindow) { win = w; break; } }
        if (!win && [wins count]) win = wins[0];
        if (!win) return nil;
        
        // 遮罩
        UIView *mask = [[UIView alloc] initWithFrame:win.bounds];
        mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        mask.alpha = 0;
        mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:WXUITarget action:@selector(sheetDismiss:)];
        [mask addGestureRecognizer:tap];
        
        // 内容容器
        CGFloat h = contentHeight;
        if (h > mask.bounds.size.height * 0.8) h = mask.bounds.size.height * 0.8;
        UIView *sheet = [[UIView alloc] initWithFrame:CGRectMake(0, mask.bounds.size.height, mask.bounds.size.width, h)];
        sheet.backgroundColor = [UIColor whiteColor];
        sheet.layer.cornerRadius = 16;
        sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        sheet.clipsToBounds = YES;
        sheet.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        
        if (contentView) {
            contentView.frame = sheet.bounds;
            contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [sheet addSubview:contentView];
        }
        
        [mask addSubview:sheet];
        [win addSubview:mask];

        // arm64e: 不用 block，直接设 frame
        mask.alpha = 1;
        CGRect f = sheet.frame;
        f.origin.y = mask.bounds.size.height - h;
        sheet.frame = f;
        
        WXSheetMask = mask;
        WXSheetContent = sheet;
        return sheet;
    }
}

// 简单 Action Sheet（按钮列表）
typedef struct {
    const char *title;
    NSInteger tag;
    BOOL isCancel;
    BOOL isBold;
} WXSheetItem;

static void WXActionSheetMake(const WXSheetItem *items, NSInteger count) {
    @autoreleasepool {
        CGFloat rowH = 56;
        CGFloat titleH = 44;
        CGFloat h = titleH + rowH * count + 8;
        UIView *cv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, h)];
        cv.backgroundColor = [UIColor colorWithRed:247.0/255 green:247.0/255 blue:247.0/255 alpha:1];
        
        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, cv.bounds.size.width, titleH)];
        tl.textAlignment = NSTextAlignmentCenter;
        tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        tl.textColor = [UIColor colorWithWhite:0.07 alpha:1];
        tl.backgroundColor = [UIColor whiteColor];
        tl.text = BJCStr("请选择");
        [cv addSubview:tl];
        
        // 按钮
        CGFloat y = titleH + 6;
        for (NSInteger i = 0; i < count; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(0, y, cv.bounds.size.width, rowH - 1);
            btn.backgroundColor = [UIColor whiteColor];
            btn.tag = items[i].tag;
            [btn setTitle:BJCStr(items[i].title) forState:UIControlStateNormal];
            if (items[i].isBold) {
                btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
                [btn setTitleColor:WX_THEME_COLOR forState:UIControlStateNormal];
            } else if (items[i].isCancel) {
                btn.titleLabel.font = [UIFont systemFontOfSize:16];
                [btn setTitleColor:[UIColor colorWithWhite:0.53 alpha:1] forState:UIControlStateNormal];
            } else {
                btn.titleLabel.font = [UIFont systemFontOfSize:16];
                [btn setTitleColor:[UIColor colorWithWhite:0.07 alpha:1] forState:UIControlStateNormal];
            }
            [btn addTarget:WXUITarget action:@selector(sheetBtn:) forControlEvents:UIControlEventTouchUpInside];
            [cv addSubview:btn];
            y += rowH;
        }
        
        WXSheetShow(cv, h);
    }
}

// Sheet 按钮点击（通过 tag 路由，用通知分发）
static void WXSheetBtn(id self, SEL _cmd, UIButton *sender) {
    @autoreleasepool {
        WXLog(BJCStr("sheetBtn tag=%ld"), (long)sender.tag);
        WXSheetDismiss(nil);
        [[NSNotificationCenter defaultCenter] postNotificationName:BJCStr("WXSheetAction") object:sender];
    }
}

static void WXSheetDismissAct(id self, SEL _cmd, id s) {
    WXSheetDismiss(s);
}

// ========== 自定义日期 Picker Sheet ==========
typedef enum {
    WXSheetCtxTimeFilter = 1,
    WXSheetCtxStats = 2,
    WXSheetCtxAI = 3
} WXSheetContext;

static WXSheetContext WXCurSheetCtx = WXSheetCtxTimeFilter;
static UIDatePicker *WXDatePickerStart = nil;
static UIDatePicker *WXDatePickerEnd = nil;

// 时间过滤按钮：打开 ActionSheet
static void WXOpenTimeFilterSheet(void) {
    WXCurSheetCtx = WXSheetCtxTimeFilter;
    WXSheetItem items[] = {
        {"全部", 300, NO, NO},
        {"今天", 301, NO, NO},
        {"昨天", 302, NO, NO},
        {"近3天", 303, NO, NO},
        {"近7天", 304, NO, NO},
        {"近1月", 305, NO, NO},
        {"自定义日期", 306, NO, NO},
        {"取消", 399, YES, NO}
    };
    WXActionSheetMake(items, 8);
}

// 统计菜单
static void WXOpenStatsSheet(void) {
    WXCurSheetCtx = WXSheetCtxStats;
    WXSheetItem items[] = {
        {"今天 (类型统计)", 401, NO, NO},
        {"昨天 (类型统计)", 402, NO, NO},
        {"近1周 (类型统计)", 403, NO, NO},
        {"近1月 (类型统计)", 404, NO, NO},
        {"近1年 (类型统计)", 405, NO, NO},
        {"自定义范围 (类型统计)", 406, NO, NO},
        {"按天分布柱状图 (近30天)", 410, NO, NO},
        {"群消息排名", 420, NO, NO},
        {"取消", 499, YES, NO}
    };
    WXActionSheetMake(items, 9);
}

// AI 时间范围选择（直接在 AI 页面内用按钮，这里也提供 sheet）
static __attribute__((unused)) void WXOpenAIStartSheet(void) {
    WXCurSheetCtx = WXSheetCtxAI;
    WXSheetItem items[] = {
        {"全部记录", 500, NO, NO},
        {"今天", 501, NO, NO},
        {"昨天", 502, NO, NO},
        {"近3天", 503, NO, NO},
        {"近7天", 504, NO, NO},
        {"近1月", 505, NO, NO},
        {"自定义日期", 506, NO, NO},
        {"取消", 599, YES, NO}
    };
    WXActionSheetMake(items, 8);
}

// 自定义日期 picker 弹窗
static void WXOpenCustomDateSheet(WXSheetContext ctx) {
    @autoreleasepool {
        WXCurSheetCtx = ctx;
        CGFloat h = 320;
        UIView *cv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, h)];
        cv.backgroundColor = [UIColor whiteColor];
        
        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, cv.bounds.size.width, 44)];
        tl.textAlignment = NSTextAlignmentCenter;
        tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        tl.text = BJCStr("自定义日期范围");
        [cv addSubview:tl];
        
        UIView *sep1 = [[UIView alloc] initWithFrame:CGRectMake(0, 44, cv.bounds.size.width, 0.5)];
        sep1.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1];
        [cv addSubview:sep1];
        
        CGFloat pickerH = 100;
        // 开始日期
        UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(20, 56, 100, 24)];
        sl.font = [UIFont systemFontOfSize:13];
        sl.textColor = WX_SUBTEXT_COLOR;
        sl.text = BJCStr("开始日期");
        [cv addSubview:sl];
        
        UIDatePicker *dp1 = [[UIDatePicker alloc] initWithFrame:CGRectMake(10, 82, cv.bounds.size.width - 20, pickerH)];
        dp1.datePickerMode = UIDatePickerModeDate;
        if (@available(iOS 13.4, *)) {
            dp1.preferredDatePickerStyle = UIDatePickerStyleWheels;
        }
        dp1.maximumDate = [NSDate date];
        dp1.tag = 701;
        [cv addSubview:dp1];
        WXDatePickerStart = dp1;
        
        // 结束日期
        UILabel *el = [[UILabel alloc] initWithFrame:CGRectMake(20, 188, 100, 24)];
        el.font = [UIFont systemFontOfSize:13];
        el.textColor = WX_SUBTEXT_COLOR;
        el.text = BJCStr("结束日期");
        [cv addSubview:el];
        
        UIDatePicker *dp2 = [[UIDatePicker alloc] initWithFrame:CGRectMake(10, 214, cv.bounds.size.width - 20, pickerH)];
        dp2.datePickerMode = UIDatePickerModeDate;
        if (@available(iOS 13.4, *)) {
            dp2.preferredDatePickerStyle = UIDatePickerStyleWheels;
        }
        dp2.maximumDate = [NSDate date];
        dp2.tag = 702;
        [cv addSubview:dp2];
        WXDatePickerEnd = dp2;
        
        // 确定按钮（底部）
        UIButton *ok = [UIButton buttonWithType:UIButtonTypeSystem];
        ok.frame = CGRectMake(0, h - 50, cv.bounds.size.width / 2, 50);
        ok.backgroundColor = WX_THEME_COLOR;
        [ok setTitle:BJCStr("确定") forState:UIControlStateNormal];
        [ok setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        ok.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        ok.tag = 710;
        [ok addTarget:WXUITarget action:@selector(dateSheetOk:) forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:ok];
        
        UIButton *cc = [UIButton buttonWithType:UIButtonTypeSystem];
        cc.frame = CGRectMake(cv.bounds.size.width / 2, h - 50, cv.bounds.size.width / 2, 50);
        cc.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1];
        [cc setTitle:BJCStr("取消") forState:UIControlStateNormal];
        cc.titleLabel.font = [UIFont systemFontOfSize:16];
        cc.tag = 711;
        [cc addTarget:WXUITarget action:@selector(dateSheetCancel:) forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:cc];
        
        WXSheetShow(cv, h);
    }
}

static void WXDateSheetOk(id self, SEL _cmd, id sender) {
    @autoreleasepool {
        if (!WXDatePickerStart || !WXDatePickerEnd) { WXSheetDismiss(nil); return; }
        NSDate *sd = WXDatePickerStart.date;
        NSDate *ed = WXDatePickerEnd.date;
        if (!sd || !ed || [ed timeIntervalSinceDate:sd] < 0) {
            // 无效
            WXSheetDismiss(nil);
            return;
        }
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDate *sdStart = [cal startOfDayForDate:sd];
        NSDateComponents *oneDay = [[NSDateComponents alloc] init];
        oneDay.day = 1; oneDay.second = -1;
        NSDate *edEnd = [cal dateByAddingComponents:oneDay toDate:[cal startOfDayForDate:ed] options:0];
        long long s = (long long)[sdStart timeIntervalSince1970];
        long long e = (long long)[edEnd timeIntervalSince1970];
        
        WXSheetDismiss(nil);
        
        // 通知
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[BJCStr("start")] = @(s);
        info[BJCStr("end")] = @(e);
        info[BJCStr("ctx")] = @(WXCurSheetCtx);
        [[NSNotificationCenter defaultCenter] postNotificationName:BJCStr("WXCustomDateOK") object:nil userInfo:info];
    }
}

static void WXDateSheetCancel(id self, SEL _cmd, id sender) {
    WXSheetDismiss(nil);
}

// =====================================================================
// 聊天记录 VC：WXChatVC
// =====================================================================
Class WXChatVCClass = Nil;

// 重建 WXChatDisplay（按天分组分隔符）
static void WXChatRebuildDisplay(void) {
    @autoreleasepool {
        if (!WXChatMsgs) return;
        WXChatDisplay = [NSMutableArray array];
        NSString *lastDay = nil;
        for (NSDictionary *m in WXChatMsgs) {
            long long ts = [m[BJCStr("CreateTime")] longLongValue];
            NSString *day = WXFmtDay(ts);
            if (![day isEqualToString:lastDay]) {
                [WXChatDisplay addObject:@{BJCStr("_isDay"): @YES, BJCStr("day"): day}];
                lastDay = day;
            }
            [WXChatDisplay addObject:m];
        }
    }
}

// 后台加载消息（分页）
static void WXChatLoadMoreBG(void *ctx) {
    @autoreleasepool {
        if (WXChatLoading) return;
        WXChatLoading = YES;
        NSArray *batch;
        if (WXCurRange == WXRangeCustom && WXRangeStart > 0 && WXRangeEnd > WXRangeStart) {
            batch = WXFetchMessagesRangeDB(WXSessDB, WXSessTable, WXRangeStart, WXRangeEnd, WXChatOffset, 50);
        } else if (WXCurRange != WXRangeAll) {
            long long s = 0, e = 0;
            WXCalcRange(WXCurRange, &s, &e, 0, 0);
            batch = WXFetchMessagesRangeDB(WXSessDB, WXSessTable, s, e, WXChatOffset, 50);
        } else {
            batch = WXFetchMessages(WXSessDB, WXSessTable, WXChatOffset, 50);
        }
        WXLog(BJCStr("chat load batch=%lu offset=%d range=%ld"), (unsigned long)[batch count], WXChatOffset, (long)WXCurRange);
        
        if (![batch count]) {
            WXChatAllLoaded = YES;
        } else {
            if (!WXChatMsgs) WXChatMsgs = [NSMutableArray array];
            // 注意：WXFetchMessages 返回正序，已加载的是较早的（offset越大越老）
            // 我们把新 batch 放到前面（因为是往上翻加载更老的）
            NSRange r = NSMakeRange(0, [batch count]);
            NSIndexSet *idx = [NSIndexSet indexSetWithIndexesInRange:r];
            [WXChatMsgs insertObjects:batch atIndexes:idx];
            WXChatOffset += [batch count];
            WXChatRebuildDisplay();
        }
        WXChatLoading = NO;
        
        dispatch_async_f(dispatch_get_main_queue(), NULL, (dispatch_function_t)WXChatReloadUI);
    }
}

static void WXChatReloadUI(void *ctx) {
    @autoreleasepool {
        if (!WXChatVCInstance) return;
        UIView *v = BJ_MSG_SEND0(WXChatVCInstance, sel_registerName("view"));
        for (UIView *s in v.subviews) {
            if ([s isKindOfClass:[UITableView class]]) {
                [(UITableView *)s reloadData];
            }
        }
    }
}

// 应用时间范围（聊天）
static void WXChatApplyRange(WXRangeType type, long long s, long long e) {
    @autoreleasepool {
        WXCurRange = type;
        if (type == WXRangeCustom) {
            WXRangeStart = s; WXRangeEnd = e;
        } else {
            WXCalcRange(type, &WXRangeStart, &WXRangeEnd, 0, 0);
        }
        WXChatMsgs = nil; WXChatDisplay = nil;
        WXChatOffset = 0; WXChatAllLoaded = NO;
        WXChatSearchMode = NO; WXChatSearchResult = nil;
        WXChatReloadUI(NULL);
        dispatch_async_f(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                         NULL, (dispatch_function_t)WXChatLoadMoreBG);
        
        // 更新按钮文字
        if (!WXChatVCInstance) return;
        UIView *v = BJ_MSG_SEND0(WXChatVCInstance, sel_registerName("view"));
        // tag=300 是时间按钮
        UIView *nav = [WXNav valueForKey:BJCStr("navigationBar")];
        // 直接改 navigationItem
        UINavigationItem *ni = [WXChatVCInstance performSelector:@selector(navigationItem)];
        // 找到 titleView 中的时间按钮不好办，重新设置按钮
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = 105;
        [btn setTitle:WXRangeLabel(WXCurRange) forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor colorWithRed:230.0/255 green:67.0/255 blue:64.0/255 alpha:1] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [btn sizeToFit];
        [btn addTarget:WXUITarget action:@selector(uiAct:) forControlEvents:UIControlEventTouchUpInside];
        UIBarButtonItem *bbi = [[UIBarButtonItem alloc] initWithCustomView:btn];
        [ni setRightBarButtonItems:@[
            bbi,
            WXMakeBarBtn(BJCStr("AI研究"), 104),
            WXMakeBarBtn(BJCStr("统计"), 103),
            WXMakeBarBtn(BJCStr("搜索"), 102)
        ]];
    }
}

// 搜索聊天消息（后台）
static void WXChatDoSearch(void *kwPtr) {
    @autoreleasepool {
        NSString *kw = (__bridge_transfer NSString *)kwPtr;
        if (![kw length]) {
            // 退出搜索
            WXChatSearchMode = NO;
            WXChatSearchResult = nil;
            dispatch_async_f(dispatch_get_main_queue(), NULL, (dispatch_function_t)WXChatReloadUI);
            return;
        }
        NSArray *res = WXSearchMessages(WXSessDB, WXSessTable, kw, 100);
        WXChatSearchResult = [res mutableCopy];
        WXChatSearchMode = YES;
        WXLog(BJCStr("chat search hits=%lu kw=%@"), (unsigned long)[WXChatSearchResult count], kw);
        dispatch_async_f(dispatch_get_main_queue(), NULL, (dispatch_function_t)WXChatReloadUI);
    }
}

// 聊天 VC viewDidLoad
static void WXChatVCViewDidLoad(id self, SEL _cmd) {
    @autoreleasepool {
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        [v setBackgroundColor:WX_BG_COLOR];
        
        UINavigationItem *ni = [self performSelector:@selector(navigationItem)];
        ni.title = WXSessName ?: BJCStr("聊天");
        
        ni.leftBarButtonItem = WXMakeBackBtn();
        
        // 右侧按钮：搜索、统计、AI研究、时间过滤
        UIButton *tBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        tBtn.tag = 105;
        [tBtn setTitle:BJCStr("全部") forState:UIControlStateNormal];
        [tBtn setTitleColor:[UIColor colorWithRed:230.0/255 green:67.0/255 blue:64.0/255 alpha:1] forState:UIControlStateNormal];
        tBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [tBtn sizeToFit];
        [tBtn addTarget:WXUITarget action:@selector(uiAct:) forControlEvents:UIControlEventTouchUpInside];
        UIBarButtonItem *tbbi = [[UIBarButtonItem alloc] initWithCustomView:tBtn];
        
        ni.rightBarButtonItems = @[
            tbbi,
            WXMakeBarBtn(BJCStr("AI研究"), 104),
            WXMakeBarBtn(BJCStr("统计"), 103),
            WXMakeBarBtn(BJCStr("搜索"), 102)
        ];
        
        // 搜索栏（默认隐藏）
        UISearchBar *sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, v.bounds.size.width, 56)];
        sb.hidden = YES;
        sb.placeholder = BJCStr("搜索聊天记录…");
        sb.barTintColor = WX_BG_COLOR;
        sb.searchBarStyle = UISearchBarStyleMinimal;
        sb.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        sb.tag = 1;
        // 找到 textfield 绑定通知
        for (UIView *sub in sb.subviews) {
            for (UIView *ss in sub.subviews) {
                if ([ss isKindOfClass:[UITextField class]]) {
                    UITextField *tf = (UITextField *)ss;
                    tf.tag = 7789;
                    [[NSNotificationCenter defaultCenter] addObserver:WXUITarget
                                                             selector:@selector(chatSearchChanged:)
                                                                 name:UITextFieldTextDidChangeNotification
                                                               object:tf];
                }
            }
        }
        [v addSubview:sb];
        
        // 消息列表
        UITableView *tv = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, v.bounds.size.width, v.bounds.size.height)
                                                        style:UITableViewStylePlain];
        [tv setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
        [tv setBackgroundColor:[UIColor clearColor]];
        [tv setSeparatorStyle:UITableViewCellSeparatorStyleNone];
        [tv setContentInset:UIEdgeInsetsMake(8, 0, 8, 0)];
        // 翻转（让最新消息贴底）- 简单起见不翻转，正序从上到下（老→新），初始滚到底
        tv.dataSource = (id<UITableViewDataSource>)self;
        tv.delegate = (id<UITableViewDelegate>)self;
        tv.tag = 2;
        [v addSubview:tv];
        
        // 监听
        [[NSNotificationCenter defaultCenter] addObserver:(id)self
                                                 selector:@selector(onUIAction:)
                                                     name:BJCStr("WXUIAction")
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:(id)self
                                                 selector:@selector(onSheetAction:)
                                                     name:BJCStr("WXSheetAction")
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:(id)self
                                                 selector:@selector(onCustomDate:)
                                                     name:BJCStr("WXCustomDateOK")
                                                   object:nil];
        
        // 初始加载
        WXChatMsgs = nil; WXChatDisplay = nil;
        WXChatOffset = 0; WXChatAllLoaded = NO;
        dispatch_async_f(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                         NULL, (dispatch_function_t)WXChatLoadMoreBG);
    }
}

// 聊天 VC：UI 动作
static void WXChatVCOnAction(id self, SEL _cmd, NSNotification *n) {
    @autoreleasepool {
        id sender = [n object];
        if (![sender respondsToSelector:@selector(tag)]) return;
        NSInteger tag = [sender tag];
        WXLog(BJCStr("chatVC onAction tag=%ld"), (long)tag);
        
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        UISearchBar *sb = (UISearchBar *)[v viewWithTag:1];
        UITableView *tv = (UITableView *)[v viewWithTag:2];
        
        if (tag == 102) { // 搜索 toggle
            BOOL show = sb ? !sb.hidden : YES;
            if (sb) {
                sb.hidden = !show;
                CGRect tf = tv.frame;
                if (show) {
                    tf.origin.y = 56; tf.size.height = v.bounds.size.height - 56;
                } else {
                    tf.origin.y = 0; tf.size.height = v.bounds.size.height;
                }
                tv.frame = tf;
                if (show) {
                    for (UIView *sub in sb.subviews) {
                        for (UIView *ss in sub.subviews) {
                            if ([ss isKindOfClass:[UITextField class]]) {
                                [(UITextField *)ss becomeFirstResponder];
                            }
                        }
                    }
                } else {
                    // 退出搜索模式（arm64e: 不用 block，直接内联）
                    WXChatSearchMode = NO;
                    WXChatSearchResult = nil;
                    [tv reloadData];
                }
            }
        } else if (tag == 103) { // 统计
            WXOpenStatsSheet();
        } else if (tag == 104) { // AI 研究
            // 进入 AI VC
            extern void WXRegisterAIVC(void);
            extern Class WXAIVCClass;
            WXRegisterAIVC();
            if (!WXAIVCInstance && WXAIVCClass) {
                WXAIVCInstance = [[WXAIVCClass alloc] init];
            }
            if (WXAIVCInstance) {
                WXNavPush(WXAIVCInstance, YES);
            }
        } else if (tag == 105) { // 时间过滤
            WXOpenTimeFilterSheet();
        }
    }
}

// 聊天 VC：Sheet 动作
static void WXChatVCOnSheet(id self, SEL _cmd, NSNotification *n) {
    @autoreleasepool {
        if (WXCurSheetCtx != WXSheetCtxTimeFilter && WXCurSheetCtx != WXSheetCtxStats) return;
        id sender = [n object];
        if (![sender respondsToSelector:@selector(tag)]) return;
        NSInteger tag = [sender tag];
        WXLog(BJCStr("chatVC sheet tag=%ld ctx=%ld"), (long)tag, (long)WXCurSheetCtx);
        
        if (WXCurSheetCtx == WXSheetCtxTimeFilter) {
            if (tag == 300) WXChatApplyRange(WXRangeAll, 0, 0);
            else if (tag == 301) WXChatApplyRange(WXRangeToday, 0, 0);
            else if (tag == 302) WXChatApplyRange(WXRangeYesterday, 0, 0);
            else if (tag == 303) WXChatApplyRange(WXRange3Days, 0, 0);
            else if (tag == 304) WXChatApplyRange(WXRange7Days, 0, 0);
            else if (tag == 305) WXChatApplyRange(WXRange30Days, 0, 0);
            else if (tag == 306) WXOpenCustomDateSheet(WXSheetCtxTimeFilter);
        } else if (WXCurSheetCtx == WXSheetCtxStats) {
            // 统计 → 进入统计 VC
            long long now = (long long)[[NSDate date] timeIntervalSince1970];
            long long s = 0, e = now;
            BOOL isGroupRank = NO;
            BOOL isDayDist = NO;
            if (tag == 401) { NSCalendar *cal = [NSCalendar currentCalendar]; s = (long long)[[cal startOfDayForDate:[NSDate date]] timeIntervalSince1970]; }
            else if (tag == 402) { NSCalendar *cal = [NSCalendar currentCalendar]; e = (long long)[[cal startOfDayForDate:[NSDate date]] timeIntervalSince1970]; s = e - 86400; }
            else if (tag == 403) { s = now - 7 * 86400; }
            else if (tag == 404) { s = now - 30 * 86400; }
            else if (tag == 405) { s = now - 365 * 86400; }
            else if (tag == 406) { WXOpenCustomDateSheet(WXSheetCtxStats); return; }
            else if (tag == 410) { isDayDist = YES; }
            else if (tag == 420) { isGroupRank = YES; }
            
            extern void WXRegisterStatsVC(void);
            extern Class WXStatsVCClass;
            extern void WXStatsVCSetMode(long long s, long long e, int mode); // 0=detail 1=dayDist 2=groupRank
            WXRegisterStatsVC();
            WXStatsVCSetMode(s, e, isGroupRank ? 2 : (isDayDist ? 1 : 0));
            if (!WXStatsVCInstance && WXStatsVCClass) {
                WXStatsVCInstance = [[WXStatsVCClass alloc] init];
            }
            if (WXStatsVCInstance) {
                WXNavPush(WXStatsVCInstance, YES);
            }
        }
    }
}

// 聊天 VC：自定义日期
static void WXChatVCOnCustomDate(id self, SEL _cmd, NSNotification *n) {
    @autoreleasepool {
        NSDictionary *info = [n userInfo];
        if (!info) return;
        WXSheetContext ctx = (WXSheetContext)[info[BJCStr("ctx")] integerValue];
        long long s = [info[BJCStr("start")] longLongValue];
        long long e = [info[BJCStr("end")] longLongValue];
        if (ctx == WXSheetCtxTimeFilter) {
            WXChatApplyRange(WXRangeCustom, s, e);
        } else if (ctx == WXSheetCtxStats) {
            extern void WXRegisterStatsVC(void);
            extern Class WXStatsVCClass;
            extern void WXStatsVCSetMode(long long s, long long e, int mode);
            WXRegisterStatsVC();
            WXStatsVCSetMode(s, e, 0);
            if (!WXStatsVCInstance && WXStatsVCClass) {
                WXStatsVCInstance = [[WXStatsVCClass alloc] init];
            }
            if (WXStatsVCInstance) {
                WXNavPush(WXStatsVCInstance, YES);
            }
        }
    }
}

// 聊天 VC 搜索变化
static void WXChatSearchChanged(id self, SEL _cmd, NSNotification *n) {
    @autoreleasepool {
        UITextField *tf = [n object];
        NSString *kw = [tf text];
        WXLog(BJCStr("chat search kw=%@"), kw);
        dispatch_async_f(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                         (void *)CFBridgingRetain([kw copy]), (dispatch_function_t)WXChatDoSearch);
    }
}

// 聊天 VC：行数
static NSInteger WXChatVCRows(id self, SEL _cmd, UITableView *tv, NSInteger sec) {
    if (WXChatSearchMode) {
        return [WXChatSearchResult count] + ([WXChatSearchResult count] ? 0 : 1);
    }
    NSInteger n = WXChatDisplay ? [WXChatDisplay count] : 0;
    return n + (WXChatAllLoaded ? 0 : 1); // 底部 loading
}

// 聊天 VC：行高
static CGFloat WXChatVCHeight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (WXChatSearchMode) {
        NSInteger row = [ip row];
        if (row >= [WXChatSearchResult count]) return 44;
        return 80;
    }
    NSInteger row = [ip row];
    if (WXChatDisplay && row < [WXChatDisplay count]) {
        id item = WXChatDisplay[row];
        if ([item isKindOfClass:[NSDictionary class]] && [item[BJCStr("_isDay")] boolValue]) {
            return 36;
        }
        // 消息气泡：根据内容估算
        NSDictionary *m = item;
        int type = (int)[m[BJCStr("Type")] longLongValue];
        NSString *text = WXFmtMsg(type, m[BJCStr("Message")]);
        CGFloat maxW = tv.bounds.size.width * 0.68;
        CGRect r = [text boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin
                                    attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:16]}
                                       context:nil];
        return r.size.height + 36; // padding + avatar 空隙
    }
    return 44; // loading
}

// 聊天 VC：cell
static UITableViewCell *WXChatVCCell(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    @autoreleasepool {
        NSInteger row = [ip row];
        
        if (WXChatSearchMode) {
            static NSString *cid = @"ChatSearchCell";
            UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
                cell.backgroundColor = [UIColor clearColor];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                
                UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(14, 6, tv.bounds.size.width - 28, 56)];
                bubble.backgroundColor = WX_CARD_COLOR;
                bubble.layer.cornerRadius = 12;
                bubble.layer.borderWidth = 1;
                bubble.layer.borderColor = [WX_BORDER_COLOR CGColor];
                bubble.tag = 10;
                bubble.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                [cell.contentView addSubview:bubble];
                
                UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, bubble.bounds.size.width - 28, 16)];
                tl.font = [UIFont systemFontOfSize:12];
                tl.textColor = WX_SUBTEXT_COLOR;
                tl.tag = 11;
                [bubble addSubview:tl];
                
                UILabel *ml = [[UILabel alloc] initWithFrame:CGRectMake(14, 28, bubble.bounds.size.width - 28, 22)];
                ml.font = [UIFont systemFontOfSize:15];
                ml.textColor = WX_TEXT_COLOR;
                ml.tag = 12;
                ml.numberOfLines = 1;
                ml.lineBreakMode = NSLineBreakByTruncatingTail;
                [bubble addSubview:ml];
            }
            UIView *bubble = [cell.contentView viewWithTag:10];
            UILabel *tl = (UILabel *)[bubble viewWithTag:11];
            UILabel *ml = (UILabel *)[bubble viewWithTag:12];
            if (row >= [WXChatSearchResult count]) {
                static NSString *ecid = @"ChatEmptyCell";
                UITableViewCell *ec = [tv dequeueReusableCellWithIdentifier:ecid];
                if (!ec) { ec = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ecid]; ec.backgroundColor = [UIColor clearColor]; ec.selectionStyle = UITableViewCellSelectionStyleNone; }
                ec.textLabel.text = BJCStr("（无更多结果）");
                ec.textLabel.textColor = WX_SUBTEXT_COLOR;
                ec.textLabel.textAlignment = NSTextAlignmentCenter;
                ec.textLabel.font = [UIFont systemFontOfSize:13];
                return ec;
            }
            NSDictionary *m = WXChatSearchResult[row];
            long long ts = [m[BJCStr("CreateTime")] longLongValue];
            int type = (int)[m[BJCStr("Type")] longLongValue];
            tl.text = [NSString stringWithFormat:BJCStr("%@"), WXFmtDay(ts)];
            ml.text = WXFmtMsg(type, m[BJCStr("Message")]);
            return cell;
        }
        
        // 正常模式
        if (WXChatDisplay && row < [WXChatDisplay count]) {
            id item = WXChatDisplay[row];
            if ([item isKindOfClass:[NSDictionary class]] && [item[BJCStr("_isDay")] boolValue]) {
                static NSString *dcid = @"ChatDayCell";
                UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:dcid];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:dcid];
                    cell.backgroundColor = [UIColor clearColor];
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, tv.bounds.size.width, 16)];
                    lbl.tag = 11;
                    lbl.textAlignment = NSTextAlignmentCenter;
                    lbl.font = [UIFont systemFontOfSize:12];
                    lbl.textColor = WX_SUBTEXT_COLOR;
                    UIView *bg = [[UIView alloc] initWithFrame:CGRectMake(tv.bounds.size.width/2 - 80, 8, 160, 20)];
                    bg.tag = 10;
                    bg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
                    bg.layer.cornerRadius = 8;
                    bg.layer.borderWidth = 1;
                    bg.layer.borderColor = [WX_BORDER_COLOR CGColor];
                    bg.center = CGPointMake(tv.bounds.size.width/2, 18);
                    [cell.contentView addSubview:bg];
                    [cell.contentView addSubview:lbl];
                }
                UILabel *lbl = (UILabel *)[cell.contentView viewWithTag:11];
                lbl.text = item[BJCStr("day")];
                return cell;
            }
            
            // 消息气泡
            static NSString *mcid = @"ChatMsgCell";
            UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:mcid];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:mcid];
                cell.backgroundColor = [UIColor clearColor];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            // 清理旧 subviews（因为复用需要重建布局）
            for (UIView *s in cell.contentView.subviews) [s removeFromSuperview];
            
            NSDictionary *m = item;
            BOOL isMe = [m[BJCStr("isMe")] boolValue];
            int type = (int)[m[BJCStr("Type")] longLongValue];
            NSString *text = WXFmtMsg(type, m[BJCStr("Message")]);
            long long ts = [m[BJCStr("CreateTime")] longLongValue];
            
            // 头像
            UIView *av = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
            av.layer.cornerRadius = 17;
            av.clipsToBounds = YES;
            if (isMe) {
                av.backgroundColor = WX_THEME_COLOR;
                av.frame = CGRectMake(tv.bounds.size.width - 44, 4, 34, 34);
            } else {
                av.backgroundColor = WXAvColor(WXSessName ?: BJCStr("T"));
                av.frame = CGRectMake(10, 4, 34, 34);
            }
            UILabel *al = [[UILabel alloc] initWithFrame:av.bounds];
            al.textAlignment = NSTextAlignmentCenter;
            al.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            al.textColor = [UIColor whiteColor];
            al.text = isMe ? BJCStr("我") : ([WXSessName length] ? [WXSessName substringToIndex:1] : BJCStr("T"));
            [av addSubview:al];
            [cell.contentView addSubview:av];
            
            // 气泡
            CGFloat maxW = tv.bounds.size.width * 0.68;
            CGRect r = [text boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
                                           options:NSStringDrawingUsesLineFragmentOrigin
                                        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:16]}
                                           context:nil];
            CGFloat bw = r.size.width + 28;
            CGFloat bh = r.size.height + 20;
            if (bw < 40) bw = 40;
            UIView *bubble = [[UIView alloc] init];
            bubble.layer.cornerRadius = 14;
            if (isMe) {
                bubble.backgroundColor = WX_ME_BUBBLE;
                bubble.frame = CGRectMake(tv.bounds.size.width - 44 - 8 - bw, 2, bw, bh);
                // 右上角切圆角
                UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bubble.bounds
                                                           byRoundingCorners:UIRectCornerTopLeft | UIRectCornerBottomLeft | UIRectCornerBottomRight
                                                                 cornerRadii:CGSizeMake(14, 14)];
                CAShapeLayer *mask = [CAShapeLayer layer];
                mask.path = path.CGPath;
                bubble.layer.mask = mask;
            } else {
                bubble.backgroundColor = WX_CARD_COLOR;
                bubble.layer.borderWidth = 1;
                bubble.layer.borderColor = [WX_BORDER_COLOR CGColor];
                bubble.frame = CGRectMake(52, 2, bw, bh);
                UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bubble.bounds
                                                           byRoundingCorners:UIRectCornerTopRight | UIRectCornerBottomLeft | UIRectCornerBottomRight
                                                                 cornerRadii:CGSizeMake(14, 14)];
                CAShapeLayer *mask = [CAShapeLayer layer];
                mask.path = path.CGPath;
                bubble.layer.mask = mask;
            }
            [cell.contentView addSubview:bubble];
            
            UILabel *ml = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, bw - 28, bh - 20)];
            ml.font = [UIFont systemFontOfSize:16];
            ml.textColor = WX_TEXT_COLOR;
            ml.numberOfLines = 0;
            ml.text = text;
            if (type != 1 && type != 10000) {
                ml.textColor = WX_THEME_COLOR;
            }
            [bubble addSubview:ml];
            
            // 时间
            UILabel *tl = [[UILabel alloc] init];
            tl.font = [UIFont systemFontOfSize:11];
            tl.textColor = [UIColor colorWithRed:189.0/255 green:195.0/255 blue:199.0/255 alpha:1];
            tl.text = WXFmtTime(ts);
            [tl sizeToFit];
            if (isMe) {
                tl.frame = CGRectMake(tv.bounds.size.width - 44 - 8 - bw - tl.frame.size.width - 4,
                                      bh - 12, tl.frame.size.width, tl.frame.size.height);
            } else {
                tl.frame = CGRectMake(52 + bw + 4, bh - 12, tl.frame.size.width, tl.frame.size.height);
            }
            [cell.contentView addSubview:tl];
            
            return cell;
        }
        
        // loading cell
        static NSString *lcid = @"ChatLoadCell";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:lcid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:lcid];
            cell.backgroundColor = [UIColor clearColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.textLabel.text = BJCStr("⬆︎ 上滑加载更老消息…");
        cell.textLabel.textColor = WX_SUBTEXT_COLOR;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        return cell;
    }
}

// 聊天 VC：将显示（翻页加载）
static void WXChatVCWillDisplay(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    @autoreleasepool {
        if (WXChatSearchMode) return;
        NSInteger last = [tv numberOfRowsInSection:0] - 1;
        // 当显示到倒数第 5 行时加载更多（注意：我们老消息在上面，所以显示到第 0-5 行时加载）
        if ([ip row] <= 5 && !WXChatLoading && !WXChatAllLoaded) {
            dispatch_async_f(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                             NULL, (dispatch_function_t)WXChatLoadMoreBG);
        }
    }
}

// 注册聊天 VC
void WXRegisterChatVC(void) {
    if (WXChatVCClass) return;
    Class cls = objc_allocateClassPair([UIViewController class], "WXChatVC", 0);
    class_addMethod(cls, sel_registerName("viewDidLoad"), (IMP)WXChatVCViewDidLoad, "v@:");
    class_addMethod(cls, sel_registerName("onUIAction:"), (IMP)WXChatVCOnAction, "v@:@");
    class_addMethod(cls, sel_registerName("onSheetAction:"), (IMP)WXChatVCOnSheet, "v@:@");
    class_addMethod(cls, sel_registerName("onCustomDate:"), (IMP)WXChatVCOnCustomDate, "v@:@");
    class_addMethod(cls, sel_registerName("tableView:numberOfRowsInSection:"), (IMP)WXChatVCRows, "l@:@@:l");
    class_addMethod(cls, sel_registerName("tableView:cellForRowAtIndexPath:"), (IMP)WXChatVCCell, "@@:@@:@");
    class_addMethod(cls, sel_registerName("tableView:heightForRowAtIndexPath:"), (IMP)WXChatVCHeight, "d@:@@:@");
    class_addMethod(cls, sel_registerName("tableView:willDisplayCell:forRowAtIndexPath:"), (IMP)WXChatVCWillDisplay, "v@:@@:@@:@");
    objc_registerClassPair(cls);
    WXChatVCClass = cls;
    
    // 往 WXUITarget 追加聊天搜索和日期 sheet 方法
    if (WXUITargetCls && !class_getInstanceMethod(WXUITargetCls, sel_registerName("chatSearchChanged:"))) {
        class_addMethod(WXUITargetCls, sel_registerName("chatSearchChanged:"), (IMP)WXChatSearchChanged, "v@:@");
    }
    if (WXUITargetCls && !class_getInstanceMethod(WXUITargetCls, sel_registerName("sheetDismiss:"))) {
        class_addMethod(WXUITargetCls, sel_registerName("sheetDismiss:"), (IMP)WXSheetDismissAct, "v@:@");
    }
    if (WXUITargetCls && !class_getInstanceMethod(WXUITargetCls, sel_registerName("sheetBtn:"))) {
        class_addMethod(WXUITargetCls, sel_registerName("sheetBtn:"), (IMP)WXSheetBtn, "v@:@");
    }
    if (WXUITargetCls && !class_getInstanceMethod(WXUITargetCls, sel_registerName("dateSheetOk:"))) {
        class_addMethod(WXUITargetCls, sel_registerName("dateSheetOk:"), (IMP)WXDateSheetOk, "v@:@");
    }
    if (WXUITargetCls && !class_getInstanceMethod(WXUITargetCls, sel_registerName("dateSheetCancel:"))) {
        class_addMethod(WXUITargetCls, sel_registerName("dateSheetCancel:"), (IMP)WXDateSheetCancel, "v@:@");
    }
}

// =====================================================================
// 统计 VC：WXStatsVC
// =====================================================================
Class WXStatsVCClass = Nil;
static NSArray *WXStatsRows = nil;
static NSArray *WXStatsDayDist = nil;
static NSArray *WXStatsRank = nil;
static int WXStatsMode = 0; // 0=detail 1=dayDist 2=groupRank
static long long WXStatsS = 0, WXStatsE = 0;

void WXStatsVCSetMode(long long s, long long e, int mode) {
    WXStatsS = s; WXStatsE = e; WXStatsMode = mode;
    WXStatsRows = nil; WXStatsDayDist = nil; WXStatsRank = nil;
}

static void WXStatsLoadBG(void *ctx) {
    @autoreleasepool {
        if (WXStatsMode == 0) {
            WXStatsRows = WXStatsDetail(WXSessDB, WXSessTable, WXStatsS, WXStatsE);
        } else if (WXStatsMode == 1) {
            WXStatsDayDist = WXStatsByDay(WXSessDB, WXSessTable, 30);
        } else {
            WXStatsRank = WXGroupRank(WXSessDB, WXSessTable, WXStatsS, WXStatsE);
        }
        dispatch_async_f(dispatch_get_main_queue(), NULL, (dispatch_function_t)WXStatsReload);
    }
}
static void WXStatsReload(void *ctx) {
    @autoreleasepool {
        if (!WXStatsVCInstance) return;
        UIView *v = BJ_MSG_SEND0(WXStatsVCInstance, sel_registerName("view"));
        for (UIView *s in v.subviews) {
            if ([s isKindOfClass:[UITableView class]] || [s isKindOfClass:[UIScrollView class]]) {
                if ([s isKindOfClass:[UITableView class]]) [(UITableView *)s reloadData];
                else [(UIScrollView *)s setNeedsDisplay];
            }
        }
    }
}

static void WXStatsVCViewDidLoad(id self, SEL _cmd) {
    @autoreleasepool {
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        [v setBackgroundColor:WX_BG_COLOR];
        
        UINavigationItem *ni = [self performSelector:@selector(navigationItem)];
        if (WXStatsMode == 0) ni.title = BJCStr("消息统计");
        else if (WXStatsMode == 1) ni.title = BJCStr("按天分布");
        else ni.title = BJCStr("群消息排行");
        ni.leftBarButtonItem = WXMakeBackBtn();
        
        if (WXStatsMode == 2) {
            // 排名用 UITableView
            UITableView *tv = [[UITableView alloc] initWithFrame:v.bounds style:UITableViewStylePlain];
            [tv setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
            tv.backgroundColor = [UIColor clearColor];
            tv.separatorStyle = UITableViewCellSeparatorStyleNone;
            tv.dataSource = (id<UITableViewDataSource>)self;
            tv.delegate = (id<UITableViewDelegate>)self;
            tv.tag = 1;
            [v addSubview:tv];
        } else if (WXStatsMode == 1) {
            // 按天柱状图：UIScrollView
            UIScrollView *sv = [[UIScrollView alloc] initWithFrame:v.bounds];
            sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            sv.backgroundColor = [UIColor clearColor];
            sv.tag = 2;
            [v addSubview:sv];
        } else {
            UITableView *tv = [[UITableView alloc] initWithFrame:v.bounds style:UITableViewStylePlain];
            [tv setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
            tv.backgroundColor = [UIColor clearColor];
            tv.separatorStyle = UITableViewCellSeparatorStyleNone;
            tv.dataSource = (id<UITableViewDataSource>)self;
            tv.delegate = (id<UITableViewDelegate>)self;
            tv.tag = 1;
            [v addSubview:tv];
            
            // 复制 / AI 分析
            UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, v.bounds.size.width, 80)];
            UIButton *copyB = [UIButton buttonWithType:UIButtonTypeSystem];
            copyB.frame = CGRectMake(14, 14, (v.bounds.size.width - 42) / 2, 50);
            copyB.backgroundColor = [UIColor whiteColor];
            copyB.layer.cornerRadius = 12;
            copyB.layer.borderWidth = 1;
            copyB.layer.borderColor = [WX_BORDER_COLOR CGColor];
            [copyB setTitle:BJCStr("复制文本") forState:UIControlStateNormal];
            [copyB setTitleColor:WX_TEXT_COLOR forState:UIControlStateNormal];
            copyB.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            copyB.tag = 801;
            [copyB addTarget:WXUITarget action:@selector(uiAct:) forControlEvents:UIControlEventTouchUpInside];
            [footer addSubview:copyB];
            
            UIButton *aiB = [UIButton buttonWithType:UIButtonTypeSystem];
            aiB.frame = CGRectMake(28 + (v.bounds.size.width - 42) / 2, 14, (v.bounds.size.width - 42) / 2, 50);
            aiB.backgroundColor = WX_THEME_COLOR;
            aiB.layer.cornerRadius = 12;
            [aiB setTitle:BJCStr("AI 分析") forState:UIControlStateNormal];
            [aiB setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            aiB.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            aiB.tag = 802;
            [aiB addTarget:WXUITarget action:@selector(uiAct:) forControlEvents:UIControlEventTouchUpInside];
            [footer addSubview:aiB];
            
            ni.rightBarButtonItem = nil; // 不监听其他
            
            tv.tableFooterView = footer;
        }
        
        [[NSNotificationCenter defaultCenter] addObserver:(id)self
                                                 selector:@selector(onUIAction:)
                                                     name:BJCStr("WXUIAction")
                                                   object:nil];
        
        dispatch_async_f(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                         NULL, (dispatch_function_t)WXStatsLoadBG);
    }
}

static void WXStatsVCOnAction(id self, SEL _cmd, NSNotification *n) {
    @autoreleasepool {
        id sender = [n object];
        if (![sender respondsToSelector:@selector(tag)]) return;
        NSInteger tag = [sender tag];
        if (tag == 801) { // 复制
            if (!WXStatsRows || ![WXStatsRows count]) return;
            NSDictionary *total = WXStatsRows[0];
            NSDictionary *typeMap = @{@1:@"文本",@3:@"图片",@34:@"语音",@43:@"视频",@47:@"表情",@49:@"链接",@50:@"通话",@10000:@"系统"};
            NSMutableString *txt = [NSMutableString stringWithString:BJCStr("消息统计\n")];
            for (NSInteger i = 1; i < [WXStatsRows count]; i++) {
                NSDictionary *r = WXStatsRows[i];
                NSNumber *tn = r[BJCStr("Type")];
                NSString *nm = typeMap[tn] ?: [NSString stringWithFormat:BJCStr("类型%@"), tn];
                [txt appendFormat:BJCStr("%@: %@ (我%@ / 对方%@)\n"), nm, r[BJCStr("cnt")], r[BJCStr("mine")], r[BJCStr("theirs")]];
            }
            [txt appendFormat:BJCStr("总计: %@ (我%@ / 对方%@)"), total[BJCStr("cnt")], total[BJCStr("mine")], total[BJCStr("theirs")]];
            WXCopyText(txt);
        } else if (tag == 802) { // AI 分析
            extern void WXRegisterAIVC(void);
            extern Class WXAIVCClass;
            extern void WXAIVCSetInitialRange(long long s, long long e);
            WXRegisterAIVC();
            WXAIVCSetInitialRange(WXStatsS, WXStatsE);
            if (!WXAIVCInstance && WXAIVCClass) {
                WXAIVCInstance = [[WXAIVCClass alloc] init];
            }
            if (WXAIVCInstance) {
                WXNavPush(WXAIVCInstance, YES);
            }
        }
    }
}

static NSInteger WXStatsVCRows(id self, SEL _cmd, UITableView *tv, NSInteger sec) {
    if (WXStatsMode == 0) return WXStatsRows ? [WXStatsRows count] : 0;
    if (WXStatsMode == 2) return WXStatsRank ? [WXStatsRank count] : 0;
    return 0;
}

static CGFloat WXStatsVCHeight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (WXStatsMode == 0) return (ip.row == 0) ? 64 : 56;
    return 56;
}

static UITableViewCell *WXStatsVCCell(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    @autoreleasepool {
        if (WXStatsMode == 0) {
            static NSString *cid = @"StatDetailCell";
            UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
                cell.backgroundColor = [UIColor clearColor];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UIView *row = [[UIView alloc] initWithFrame:CGRectMake(14, 4, tv.bounds.size.width - 28, 48)];
                row.backgroundColor = WX_CARD_COLOR;
                row.layer.cornerRadius = 10;
                row.layer.borderWidth = 1;
                row.layer.borderColor = [WX_BORDER_COLOR CGColor];
                row.tag = 10;
                row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                [cell.contentView addSubview:row];
                UILabel *nl = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, 120, 20)];
                nl.font = [UIFont systemFontOfSize:15]; nl.tag = 11;
                [row addSubview:nl];
                UILabel *cl = [[UILabel alloc] initWithFrame:CGRectMake(row.bounds.size.width - 180, 12, 80, 22)];
                cl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
                cl.textAlignment = NSTextAlignmentRight;
                cl.textColor = WX_THEME_COLOR; cl.tag = 12;
                cl.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
                [row addSubview:cl];
                UILabel *ml = [[UILabel alloc] initWithFrame:CGRectMake(row.bounds.size.width - 96, 16, 80, 16)];
                ml.font = [UIFont systemFontOfSize:12]; ml.tag = 13;
                ml.textAlignment = NSTextAlignmentRight; ml.textColor = WX_SUBTEXT_COLOR;
                ml.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
                [row addSubview:ml];
            }
            UIView *row = [cell.contentView viewWithTag:10];
            UILabel *nl = (UILabel *)[row viewWithTag:11];
            UILabel *cl = (UILabel *)[row viewWithTag:12];
            UILabel *ml = (UILabel *)[row viewWithTag:13];
            
            if (ip.row == 0 && [WXStatsRows count]) {
                // 总计行
                nl.text = BJCStr("总计");
                nl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
                row.backgroundColor = [UIColor colorWithRed:251.0/255 green:251.0/255 blue:251.0/255 alpha:1];
            } else {
                row.backgroundColor = WX_CARD_COLOR;
                nl.font = [UIFont systemFontOfSize:15];
            }
            NSDictionary *r = WXStatsRows[ip.row];
            if (ip.row > 0) {
                NSDictionary *typeMap = @{@1:@"文本",@3:@"图片",@34:@"语音",@43:@"视频",@47:@"表情",@49:@"链接",@50:@"通话",@10000:@"系统"};
                NSNumber *tn = r[BJCStr("Type")];
                nl.text = typeMap[tn] ?: [NSString stringWithFormat:BJCStr("类型%@"), tn];
            }
            cl.text = [r[BJCStr("cnt")] description];
            ml.text = [NSString stringWithFormat:BJCStr("我%@ / 对方%@"), r[BJCStr("mine")], r[BJCStr("theirs")]];
            return cell;
        } else {
            // 群排名
            static NSString *cid = @"RankCell";
            UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
                cell.backgroundColor = [UIColor clearColor];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UIView *row = [[UIView alloc] initWithFrame:CGRectMake(14, 4, tv.bounds.size.width - 28, 48)];
                row.backgroundColor = WX_CARD_COLOR;
                row.layer.cornerRadius = 10;
                row.layer.borderWidth = 1;
                row.layer.borderColor = [WX_BORDER_COLOR CGColor];
                row.tag = 10;
                row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                [cell.contentView addSubview:row];
                UILabel *rk = [[UILabel alloc] initWithFrame:CGRectMake(14, 11, 26, 26)];
                rk.layer.cornerRadius = 13; rk.clipsToBounds = YES;
                rk.textAlignment = NSTextAlignmentCenter;
                rk.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
                rk.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1];
                rk.textColor = [UIColor colorWithWhite:0.4 alpha:1];
                rk.tag = 11;
                [row addSubview:rk];
                UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(54, 14, row.bounds.size.width - 170, 20)];
                nm.font = [UIFont systemFontOfSize:15]; nm.tag = 12;
                nm.lineBreakMode = NSLineBreakByTruncatingTail;
                [row addSubview:nm];
                UILabel *cn = [[UILabel alloc] initWithFrame:CGRectMake(row.bounds.size.width - 100, 14, 80, 20)];
                cn.textAlignment = NSTextAlignmentRight;
                cn.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
                cn.textColor = WX_THEME_COLOR; cn.tag = 13;
                cn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
                [row addSubview:cn];
            }
            UIView *row = [cell.contentView viewWithTag:10];
            UILabel *rk = (UILabel *)[row viewWithTag:11];
            UILabel *nm = (UILabel *)[row viewWithTag:12];
            UILabel *cn = (UILabel *)[row viewWithTag:13];
            NSDictionary *r = WXStatsRank[ip.row];
            NSInteger rank = ip.row + 1;
            rk.text = [NSString stringWithFormat:BJCStr("%ld"), (long)rank];
            if (rank == 1) { rk.backgroundColor = [UIColor colorWithRed:1 green:214.0/255 blue:10.0/255 alpha:1]; rk.textColor = [UIColor colorWithWhite:0.2 alpha:1]; }
            else if (rank == 2) { rk.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1]; rk.textColor = [UIColor colorWithWhite:0.33 alpha:1]; }
            else if (rank == 3) { rk.backgroundColor = [UIColor colorWithRed:232.0/255 green:180.0/255 blue:138.0/255 alpha:1]; rk.textColor = [UIColor whiteColor]; }
            else { rk.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1]; rk.textColor = [UIColor colorWithWhite:0.4 alpha:1]; }
            nm.text = r[BJCStr("name")] ?: r[BJCStr("sender")];
            cn.text = [NSString stringWithFormat:BJCStr("%@条"), r[BJCStr("cnt")]];
            return cell;
        }
    }
}

// 按天分布柱状图
// viewDidLayoutSubviews - 绘制按天柱状图
static void WXStatsVCLayout(id self, SEL _cmd) {
    @autoreleasepool {
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        UIScrollView *sv = (UIScrollView *)[v viewWithTag:2];
        if (!sv || WXStatsMode != 1 || !WXStatsDayDist) return;
        
        // 清空旧的
        for (UIView *s in sv.subviews) [s removeFromSuperview];
        
        NSInteger count = [WXStatsDayDist count];
        if (!count) return;
        long long max = 1;
        for (NSDictionary *d in WXStatsDayDist) {
            long long c = [d[BJCStr("cnt")] longLongValue];
            if (c > max) max = c;
        }
        CGFloat barW = 44, gap = 10;
        CGFloat chartH = 220;
        CGFloat chartY = 80;
        CGFloat totalW = count * (barW + gap) + gap;
        if (totalW < sv.bounds.size.width) totalW = sv.bounds.size.width;
        sv.contentSize = CGSizeMake(totalW, sv.bounds.size.height);
        
        // 标题
        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, sv.bounds.size.width - 40, 24)];
        tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        tl.textColor = WX_TEXT_COLOR;
        tl.text = BJCStr("近30天消息分布（条/天）");
        [sv addSubview:tl];
        
        CGFloat x = gap;
        for (NSInteger i = 0; i < count; i++) {
            NSDictionary *d = WXStatsDayDist[i];
            long long c = [d[BJCStr("cnt")] longLongValue];
            CGFloat h = (CGFloat)c / (CGFloat)max * chartH;
            UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(x, chartY + chartH - h, barW, h)];
            bar.backgroundColor = WX_THEME_COLOR;
            bar.layer.cornerRadius = 4;
            [sv addSubview:bar];
            // 数量
            UILabel *cl = [[UILabel alloc] initWithFrame:CGRectMake(x, chartY + chartH - h - 18, barW, 16)];
            cl.font = [UIFont systemFontOfSize:10];
            cl.textColor = WX_SUBTEXT_COLOR;
            cl.textAlignment = NSTextAlignmentCenter;
            cl.text = [NSString stringWithFormat:BJCStr("%lld"), c];
            [sv addSubview:cl];
            // 日期
            UILabel *dl = [[UILabel alloc] initWithFrame:CGRectMake(x - 4, chartY + chartH + 4, barW + 8, 16)];
            dl.font = [UIFont systemFontOfSize:9];
            dl.textColor = WX_SUBTEXT_COLOR;
            dl.textAlignment = NSTextAlignmentCenter;
            NSString *day = d[BJCStr("day")];
            dl.text = [day length] >= 5 ? [day substringFromIndex:[day length] - 5] : day; // MM-DD
            [sv addSubview:dl];
            x += barW + gap;
        }
    }
}

void WXRegisterStatsVC(void) {
    if (WXStatsVCClass) return;
    Class cls = objc_allocateClassPair([UIViewController class], "WXStatsVC", 0);
    class_addMethod(cls, sel_registerName("viewDidLoad"), (IMP)WXStatsVCViewDidLoad, "v@:");
    class_addMethod(cls, sel_registerName("onUIAction:"), (IMP)WXStatsVCOnAction, "v@:@");
    class_addMethod(cls, sel_registerName("tableView:numberOfRowsInSection:"), (IMP)WXStatsVCRows, "l@:@@:l");
    class_addMethod(cls, sel_registerName("tableView:cellForRowAtIndexPath:"), (IMP)WXStatsVCCell, "@@:@@:@");
    class_addMethod(cls, sel_registerName("tableView:heightForRowAtIndexPath:"), (IMP)WXStatsVCHeight, "d@:@@:@");
    class_addMethod(cls, sel_registerName("viewDidLayoutSubviews"), (IMP)WXStatsVCLayout, "v@:");
    objc_registerClassPair(cls);
    WXStatsVCClass = cls;
}

// =====================================================================
// AI 研究 VC：WXAIVC
// =====================================================================
Class WXAIVCClass = Nil;
static long long WXAIIs = 0, WXAIIe = 0;
static WXRangeType WXAIRangeType = WXRangeAll;
static long long WXAIRangeStart = 0, WXAIRangeEnd = 0;
static NSMutableArray *WXAIMessages = nil; // @[@{role, content}]
static BOOL WXAIBusy = NO;
static long long WXAICbId = 0;
static UITextView *WXAITextView = nil;  // 结果展示（支持简单 markdown 渲染）
static UIView *WXAIInputContainer = nil;
static UITextField *WXAIInputField = nil;

void WXAIVCSetInitialRange(long long s, long long e) {
    WXAIIs = s; WXAIIe = e;
    if (s > 0 || e > 0) {
        WXAIRangeType = WXRangeCustom;
        WXAIRangeStart = s;
        WXAIRangeEnd = e;
    } else {
        WXAIRangeType = WXRangeAll;
        WXAIRangeStart = 0; WXAIRangeEnd = 0;
    }
}

// Markdown 简单渲染：**bold** → 加粗；# heading → 大字号；换行保留
static NSAttributedString *WXRenderMarkdown(NSString *md) {
    if (![md length]) return [[NSAttributedString alloc] initWithString:BJCStr("")];
    NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithString:md];
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[NSFontAttributeName] = [UIFont systemFontOfSize:15];
    attrs[NSForegroundColorAttributeName] = WX_TEXT_COLOR;
    [mas setAttributes:attrs range:NSMakeRange(0, [mas length])];
    
    // **bold**
    NSRegularExpression *bold = [NSRegularExpression regularExpressionWithPattern:BJCStr("\\*\\*([^\\*]+)\\*\\*") options:0 error:nil];
    NSArray *bm = [bold matchesInString:[mas string] options:0 range:NSMakeRange(0, [mas length])];
    for (NSTextCheckingResult *m in [bm reverseObjectEnumerator]) {
        NSRange r = [m rangeAtIndex:1];
        [mas addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:15] range:r];
        NSRange full = [m rangeAtIndex:0];
        [mas deleteCharactersInRange:NSMakeRange(full.location + full.length - 2, 2)];
        [mas deleteCharactersInRange:NSMakeRange(full.location, 2)];
    }
    // # heading
    NSRegularExpression *h1 = [NSRegularExpression regularExpressionWithPattern:BJCStr("^#\\s.*$") options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSArray *hm = [h1 matchesInString:[mas string] options:0 range:NSMakeRange(0, [mas length])];
    for (NSTextCheckingResult *m in [hm reverseObjectEnumerator]) {
        NSRange r = [m range];
        [mas addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:19] range:r];
        [mas addAttribute:NSForegroundColorAttributeName value:WX_THEME_COLOR range:r];
    }
    // ## h2
    NSRegularExpression *h2 = [NSRegularExpression regularExpressionWithPattern:BJCStr("^##\\s.*$") options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSArray *h2m = [h2 matchesInString:[mas string] options:0 range:NSMakeRange(0, [mas length])];
    for (NSTextCheckingResult *m in [h2m reverseObjectEnumerator]) {
        NSRange r = [m range];
        [mas addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:17] range:r];
    }
    return mas;
}

static void WXAIReloadResult(void) {
    @autoreleasepool {
        if (!WXAITextView || !WXAIMessages) return;
        NSMutableAttributedString *all = [[NSMutableAttributedString alloc] init];
        for (NSInteger i = 0; i < [WXAIMessages count]; i++) {
            NSDictionary *m = WXAIMessages[i];
            NSString *role = m[BJCStr("role")];
            NSString *content = m[BJCStr("content")];
            if ([role isEqualToString:BJCStr("user")]) {
                NSAttributedString *h = [[NSAttributedString alloc] initWithString:BJCStr("▌我：\n") attributes:@{
                    NSFontAttributeName: [UIFont boldSystemFontOfSize:14],
                    NSForegroundColorAttributeName: WX_THEME_COLOR
                }];
                [all appendAttributedString:h];
                [all appendAttributedString:WXRenderMarkdown(content)];
                [all appendAttributedString:[[NSAttributedString alloc] initWithString:BJCStr("\n\n")]];
            } else if ([role isEqualToString:BJCStr("assistant")]) {
                NSAttributedString *h = [[NSAttributedString alloc] initWithString:BJCStr("▌AI 分析：\n") attributes:@{
                    NSFontAttributeName: [UIFont boldSystemFontOfSize:14],
                    NSForegroundColorAttributeName: [UIColor colorWithRed:46.0/255 green:204.0/255 blue:113.0/255 alpha:1]
                }];
                [all appendAttributedString:h];
                [all appendAttributedString:WXRenderMarkdown(content)];
                [all appendAttributedString:[[NSAttributedString alloc] initWithString:BJCStr("\n\n")]];
            }
        }
        WXAITextView.attributedText = all;
        // 滚到底
        if ([all length]) {
            [WXAITextView scrollRangeToVisible:NSMakeRange([all length] - 1, 1)];
        }
    }
}

// Native AI 回调（替代原先 JS 回调）
void WXAICallbackNative(void *ctx) {
    @autoreleasepool {
        NSDictionary *cb = (__bridge_transfer NSDictionary *)ctx;
        BOOL ok = [cb[BJCStr("ok")] boolValue];
        NSString *content = cb[BJCStr("content")] ?: @"";
        NSString *err = cb[BJCStr("error")] ?: @"";
        WXLog(BJCStr("AI native cb ok=%d clen=%lu"), ok, (unsigned long)[content length]);
        
        if (ok && [content length]) {
            // 历史已经在 WXAIResearchMain 里添加了，我们只需要从 WXAIHistory 重建 WXAIMessages
            // WXAIHistory 含 system prompt，跳过它，展示 user/assistant
            if (!WXAIMessages) WXAIMessages = [NSMutableArray array];
            // 从 WXAIHistory 复制（跳过 system role，第一个是 system 后续跳过）
            [WXAIMessages removeAllObjects];
            for (NSInteger i = 0; i < [WXAIHistory count]; i++) {
                NSDictionary *m = WXAIHistory[i];
                if ([m[BJCStr("role")] isEqualToString:BJCStr("system")]) continue;
                [WXAIMessages addObject:m];
            }
        } else {
            if (!WXAIMessages) WXAIMessages = [NSMutableArray array];
            [WXAIMessages addObject:@{BJCStr("role"): BJCStr("assistant"), BJCStr("content"): [NSString stringWithFormat:BJCStr("❌ 失败：%@"), err]}];
        }
        WXAIBusy = NO;
        dispatch_async_f(dispatch_get_main_queue(), NULL, (dispatch_function_t)WXAIRefreshUI);
    }
}

void WXAICBEmptyNative(void *ctx) {
    @autoreleasepool {
        if (!WXAIMessages) WXAIMessages = [NSMutableArray array];
        [WXAIMessages addObject:@{BJCStr("role"): BJCStr("assistant"), BJCStr("content"): BJCStr("该时间段没有消息可供分析。")}];
        WXAIBusy = NO;
        dispatch_async_f(dispatch_get_main_queue(), NULL, (dispatch_function_t)WXAIRefreshUI);
    }
}

static void WXAIRefreshUI(void *ctx) {
    @autoreleasepool {
        WXAIReloadResult();
        if (WXAIInputField) WXAIInputField.enabled = YES;
        // 隐藏 loading
        if (WXAIVCInstance) {
            UIView *v = BJ_MSG_SEND0(WXAIVCInstance, sel_registerName("view"));
            UIView *loading = [v viewWithTag:900];
            if (loading) loading.hidden = YES;
        }
    }
}

// 启动 AI
static void WXAIStart(void) {
    @autoreleasepool {
        if (WXAIBusy) return;
        WXAIBusy = YES;
        if (WXAIInputField) WXAIInputField.enabled = NO;
        // 清空历史
        WXAIHistory = nil;
        
        // 显示 loading
        if (WXAIVCInstance) {
            UIView *v = BJ_MSG_SEND0(WXAIVCInstance, sel_registerName("view"));
            UIView *loading = [v viewWithTag:900];
            if (loading) loading.hidden = NO;
        }
        
        long long s = 0, e = 0;
        if (WXAIRangeType == WXRangeCustom) {
            s = WXAIRangeStart; e = WXAIRangeEnd;
        } else if (WXAIRangeType != WXRangeAll) {
            WXCalcRange(WXAIRangeType, &s, &e, 0, 0);
        } else {
            s = 0; e = 0;
        }
        WXAICbId++;
        WXLog(BJCStr("AI start range=%ld s=%lld e=%lld"), (long)WXAIRangeType, s, e);
        WXStartAIResearch(WXSessDB, WXSessTable, WXSessName ?: BJCStr("对方"), s, e, WXAICbId, @"");
    }
}

// AI 追问（从输入框）
static void WXAIAsk(NSString *q) {
    @autoreleasepool {
        if (![q length] || WXAIBusy) return;
        // v1.3.0: 如果还没有分析历史（用户没点"开始分析"直接追问）→ 自动按当前范围先分析
        if (![WXAIHistory count]) {
            WXLog(BJCStr("AI ask without history, auto-start analysis first"));
            // 把问题暂存为初始问题，走 WXAIStart 流程
            WXAIBusy = YES;
            if (WXAIInputField) WXAIInputField.enabled = NO;
            if (WXAIVCInstance) {
                UIView *v = BJ_MSG_SEND0(WXAIVCInstance, sel_registerName("view"));
                UIView *loading = [v viewWithTag:900];
                if (loading) loading.hidden = NO;
            }
            WXAIHistory = nil;
            long long s = 0, e = 0;
            if (WXAIRangeType == WXRangeCustom) {
                s = WXAIRangeStart; e = WXAIRangeEnd;
            } else if (WXAIRangeType != WXRangeAll) {
                WXCalcRange(WXAIRangeType, &s, &e, 0, 0);
            }
            WXAICbId++;
            WXStartAIResearch(WXSessDB, WXSessTable, WXSessName ?: BJCStr("对方"), s, e, WXAICbId, q);
            return;
        }
        WXAIBusy = YES;
        if (WXAIInputField) WXAIInputField.enabled = NO;
        if (WXAIVCInstance) {
            UIView *v = BJ_MSG_SEND0(WXAIVCInstance, sel_registerName("view"));
            UIView *loading = [v viewWithTag:900];
            if (loading) loading.hidden = NO;
        }
        if (!WXAIMessages) WXAIMessages = [NSMutableArray array];
        [WXAIMessages addObject:@{BJCStr("role"): BJCStr("user"), BJCStr("content"): q}];
        WXAIReloadResult();
        WXAICbId++;
        WXStartAIResearch(@"", @"", @"", 0, 0, WXAICbId, q);
    }
}

// VC viewDidLoad
static void WXAIVCViewDidLoad(id self, SEL _cmd) {
    @autoreleasepool {
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        [v setBackgroundColor:WX_BG_COLOR];
        
        UINavigationItem *ni = [self performSelector:@selector(navigationItem)];
        ni.title = [NSString stringWithFormat:BJCStr("AI研究 - %@"), WXSessName ?: BJCStr("聊天")];
        ni.leftBarButtonItem = WXMakeBackBtn();
        // v1.3.0: 右侧"清空"按钮——重置对话上下文重新分析
        UIButton *clearB = [UIButton buttonWithType:UIButtonTypeSystem];
        [clearB setTitle:BJCStr("清空") forState:UIControlStateNormal];
        [clearB setTitleColor:WX_THEME_COLOR forState:UIControlStateNormal];
        clearB.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [clearB sizeToFit];
        clearB.tag = 697;
        [clearB addTarget:WXUITarget action:@selector(uiAct:) forControlEvents:UIControlEventTouchUpInside];
        ni.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:clearB];
        
        // 如果是从统计跳转过来的自定义范围 → 直接开始分析
        BOOL directStart = NO;
        if (WXAIIs > 0 || WXAIIe > 0) {
            WXAIRangeType = WXRangeCustom;
            WXAIRangeStart = WXAIIs;
            WXAIRangeEnd = WXAIIe;
            directStart = YES;
            WXAIIs = 0; WXAIIe = 0; // 消费
        }
        
        // 顶部卡片：时间范围按钮 + 开始按钮
        CGFloat y = 0;
        UIView *topCard = [[UIView alloc] initWithFrame:CGRectMake(14, 10, v.bounds.size.width - 28, 240)];
        topCard.backgroundColor = WX_CARD_COLOR;
        topCard.layer.cornerRadius = 12;
        topCard.layer.borderWidth = 1;
        topCard.layer.borderColor = [WX_BORDER_COLOR CGColor];
        topCard.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        topCard.tag = 10;
        [v addSubview:topCard];
        y = 10 + 240 + 10;
        
        // 标题
        UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(16, 16, topCard.bounds.size.width - 32, 22)];
        tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        tl.textColor = WX_TEXT_COLOR;
        tl.text = [NSString stringWithFormat:BJCStr("研究「%@」的聊天记录"), WXSessName ?: BJCStr("当前会话")];
        [topCard addSubview:tl];
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(16, 46, topCard.bounds.size.width - 32, 2)];
        line.backgroundColor = WX_THEME_COLOR;
        [topCard addSubview:line];
        
        // 时间范围按钮组（2行4列）
        NSArray *ranges = @[
            @{@"t":BJCStr("全部"), @"v":@(WXRangeAll)},
            @{@"t":BJCStr("今天"), @"v":@(WXRangeToday)},
            @{@"t":BJCStr("昨天"), @"v":@(WXRangeYesterday)},
            @{@"t":BJCStr("近3天"), @"v":@(WXRange3Days)},
            @{@"t":BJCStr("近7天"), @"v":@(WXRange7Days)},
            @{@"t":BJCStr("近1月"), @"v":@(WXRange30Days)},
            @{@"t":BJCStr("自定义"), @"v":@(WXRangeCustom)}
        ];
        CGFloat btnW = (topCard.bounds.size.width - 32 - 16) / 4;
        CGFloat btnH = 36;
        CGFloat by = 62;
        for (NSInteger i = 0; i < [ranges count]; i++) {
            NSInteger col = i % 4;
            NSInteger row = i / 4;
            NSDictionary *r = ranges[i];
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(16 + col * (btnW + 8), by + row * (btnH + 8), btnW, btnH);
            [btn setTitle:r[@"t"] forState:UIControlStateNormal];
            [btn setTitleColor:WX_TEXT_COLOR forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:13];
            btn.layer.cornerRadius = 10;
            btn.layer.borderWidth = 1;
            btn.layer.borderColor = [WX_BORDER_COLOR CGColor];
            btn.backgroundColor = [UIColor whiteColor];
            btn.tag = 600 + [r[@"v"] integerValue];
            // 如果当前选中
            WXRangeType cur = WXAIRangeType;
            if (cur == [r[@"v"] integerValue] || (cur == WXRangeCustom && [r[@"v"] integerValue] == WXRangeCustom)) {
                btn.backgroundColor = WX_THEME_COLOR;
                [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                btn.layer.borderColor = [WX_THEME_COLOR CGColor];
            }
            [btn addTarget:WXUITarget action:@selector(uiAct:) forControlEvents:UIControlEventTouchUpInside];
            [topCard addSubview:btn];
        }
        
        // 开始分析按钮
        UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
        go.frame = CGRectMake(16, by + 2 * (btnH + 8) + 4, topCard.bounds.size.width - 32, 46);
        go.backgroundColor = WX_THEME_COLOR;
        go.layer.cornerRadius = 12;
        [go setTitle:BJCStr("开始 AI 分析") forState:UIControlStateNormal];
        [go setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        go.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        go.tag = 699;
        [go addTarget:WXUITarget action:@selector(uiAct:) forControlEvents:UIControlEventTouchUpInside];
        [topCard addSubview:go];
        
        // 说明
        UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(20, topCard.bounds.size.height - 22, topCard.bounds.size.width - 40, 14)];
        note.font = [UIFont systemFontOfSize:12];
        note.textColor = WX_SUBTEXT_COLOR;
        note.textAlignment = NSTextAlignmentCenter;
        note.text = BJCStr("AI 引擎：DeepSeek (deepseek-chat)");
        [topCard addSubview:note];
        
        // 结果区
        CGFloat ih = 60;
        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(14, y, v.bounds.size.width - 28, v.bounds.size.height - y - ih - 10)];
        tv.backgroundColor = WX_CARD_COLOR;
        tv.layer.cornerRadius = 12;
        tv.layer.borderWidth = 1;
        tv.layer.borderColor = [WX_BORDER_COLOR CGColor];
        tv.font = [UIFont systemFontOfSize:15];
        tv.textColor = WX_TEXT_COLOR;
        tv.editable = NO;
        tv.selectable = YES; // v1.3.0: 结果可选中复制
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.textContainerInset = UIEdgeInsetsMake(14, 14, 14, 14);
        [v addSubview:tv];
        WXAITextView = tv;
        
        // Loading（居中）
        UIView *loading = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 80)];
        loading.center = CGPointMake(v.bounds.size.width/2, v.bounds.size.height/2);
        loading.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
        loading.layer.cornerRadius = 12;
        loading.hidden = YES;
        loading.tag = 900;
        loading.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        UILabel *ll = [[UILabel alloc] initWithFrame:CGRectMake(0, 44, 200, 22)];
        ll.textAlignment = NSTextAlignmentCenter;
        ll.textColor = [UIColor whiteColor];
        ll.font = [UIFont systemFontOfSize:14];
        ll.text = BJCStr("AI 分析中…");
        [loading addSubview:ll];
        UIActivityIndicatorView *ai = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
        ai.center = CGPointMake(100, 26);
        [ai startAnimating];
        [loading addSubview:ai];
        [v addSubview:loading];
        
        // 输入栏
        UIView *inputC = [[UIView alloc] initWithFrame:CGRectMake(0, v.bounds.size.height - ih, v.bounds.size.width, ih)];
        inputC.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95];
        inputC.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        inputC.layer.borderWidth = 1;
        inputC.layer.borderColor = [WX_BORDER_COLOR CGColor];
        [v addSubview:inputC];
        WXAIInputContainer = inputC;
        
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(14, 14, inputC.bounds.size.width - 110, 36)];
        tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.font = [UIFont systemFontOfSize:15];
        tf.placeholder = BJCStr("继续追问这段聊天…");
        tf.returnKeyType = UIReturnKeySend;
        tf.delegate = (id<UITextFieldDelegate>)self;
        tf.tag = 7790;
        [inputC addSubview:tf];
        WXAIInputField = tf;
        
        UIButton *sb = [UIButton buttonWithType:UIButtonTypeSystem];
        sb.frame = CGRectMake(inputC.bounds.size.width - 88, 14, 74, 36);
        sb.backgroundColor = WX_THEME_COLOR;
        sb.layer.cornerRadius = 10;
        [sb setTitle:BJCStr("发送") forState:UIControlStateNormal];
        [sb setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        sb.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        sb.tag = 698;
        [sb addTarget:WXUITarget action:@selector(uiAct:) forControlEvents:UIControlEventTouchUpInside];
        [inputC addSubview:sb];
        
        [[NSNotificationCenter defaultCenter] addObserver:(id)self
                                                 selector:@selector(onUIAction:)
                                                     name:BJCStr("WXUIAction")
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:(id)self
                                                 selector:@selector(onSheetAction:)
                                                     name:BJCStr("WXSheetAction")
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:(id)self
                                                 selector:@selector(onCustomDate:)
                                                     name:BJCStr("WXCustomDateOK")
                                                   object:nil];
        
        // 初始化消息列表
        if (!WXAIMessages) WXAIMessages = [NSMutableArray array];
        
        if (directStart) {
            // 统计跳转过来：直接开始
            WXAIStart();
        }
    }
}

// VC UI 动作
static void WXAIVCOnAction(id self, SEL _cmd, NSNotification *n) {
    @autoreleasepool {
        id sender = [n object];
        if (![sender respondsToSelector:@selector(tag)]) return;
        NSInteger tag = [sender tag];
        WXLog(BJCStr("aiVC action tag=%ld"), (long)tag);
        
        if (tag >= 600 && tag <= 699) {
            if (tag == 699) { // 开始
                WXAIStart();
            } else if (tag == 698) { // 发送
                NSString *q = [WXAIInputField text];
                [WXAIInputField setText:@""];
                [WXAIInputField resignFirstResponder];
                WXAIAsk(q);
            } else if (tag == 697) { // v1.3.0: 清空对话
                WXAIHistory = nil;
                WXAIMessages = nil;
                WXAIBusy = NO;
                if (WXAIInputField) WXAIInputField.enabled = YES;
                if (WXAIVCInstance) {
                    UIView *v = BJ_MSG_SEND0(WXAIVCInstance, sel_registerName("view"));
                    UIView *loading = [v viewWithTag:900];
                    if (loading) loading.hidden = YES;
                }
                WXLog(BJCStr("AI conversation cleared"));
                WXAIReloadResult();
            } else {
                // 时间范围
                WXRangeType t = (WXRangeType)(tag - 600);
                if (t == WXRangeCustom) {
                    WXOpenCustomDateSheet(WXSheetCtxAI);
                } else {
                    WXAIRangeType = t;
                    WXAIRangeStart = 0; WXAIRangeEnd = 0;
                }
                // 刷新按钮状态
                UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
                UIView *topCard = [v viewWithTag:10];
                for (UIView *sub in topCard.subviews) {
                    if ([sub isKindOfClass:[UIButton class]]) {
                        UIButton *b = (UIButton *)sub;
                        if (b.tag >= 600 && b.tag < 698) {
                            WXRangeType bt = (WXRangeType)(b.tag - 600);
                            BOOL on = (bt == WXAIRangeType) || (WXAIRangeType == WXRangeCustom && bt == WXRangeCustom);
                            if (on) {
                                b.backgroundColor = WX_THEME_COLOR;
                                [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                                b.layer.borderColor = [WX_THEME_COLOR CGColor];
                            } else {
                                b.backgroundColor = [UIColor whiteColor];
                                [b setTitleColor:WX_TEXT_COLOR forState:UIControlStateNormal];
                                b.layer.borderColor = [WX_BORDER_COLOR CGColor];
                            }
                        }
                    }
                }
            }
        }
    }
}

static void WXAIVCOnSheet(id self, SEL _cmd, NSNotification *n) {
    // AI 暂不需要 sheet 回调（按钮是内联的）
}

static void WXAIVCOnCustomDate(id self, SEL _cmd, NSNotification *n) {
    @autoreleasepool {
        NSDictionary *info = [n userInfo];
        if (!info) return;
        WXSheetContext ctx = (WXSheetContext)[info[BJCStr("ctx")] integerValue];
        if (ctx != WXSheetCtxAI) return;
        WXAIRangeType = WXRangeCustom;
        WXAIRangeStart = [info[BJCStr("start")] longLongValue];
        WXAIRangeEnd = [info[BJCStr("end")] longLongValue];
        // 刷新按钮
        UIView *v = BJ_MSG_SEND0(self, sel_registerName("view"));
        UIView *topCard = [v viewWithTag:10];
        for (UIView *sub in topCard.subviews) {
            if ([sub isKindOfClass:[UIButton class]]) {
                UIButton *b = (UIButton *)sub;
                if (b.tag >= 600 && b.tag < 698) {
                    WXRangeType bt = (WXRangeType)(b.tag - 600);
                    BOOL on = (bt == WXRangeCustom);
                    if (on) {
                        b.backgroundColor = WX_THEME_COLOR;
                        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                        b.layer.borderColor = [WX_THEME_COLOR CGColor];
                    } else {
                        b.backgroundColor = [UIColor whiteColor];
                        [b setTitleColor:WX_TEXT_COLOR forState:UIControlStateNormal];
                        b.layer.borderColor = [WX_BORDER_COLOR CGColor];
                    }
                }
            }
        }
    }
}

// 发送按钮（按回车）
static BOOL WXAIVCTFReturn(id self, SEL _cmd, UITextField *tf) {
    @autoreleasepool {
        NSString *q = [tf text];
        [tf setText:@""];
        [tf resignFirstResponder];
        WXAIAsk(q);
        return YES;
    }
}

void WXRegisterAIVC(void) {
    if (WXAIVCClass) return;
    Class cls = objc_allocateClassPair([UIViewController class], "WXAIVC", 0);
    class_addMethod(cls, sel_registerName("viewDidLoad"), (IMP)WXAIVCViewDidLoad, "v@:");
    class_addMethod(cls, sel_registerName("onUIAction:"), (IMP)WXAIVCOnAction, "v@:@");
    class_addMethod(cls, sel_registerName("onSheetAction:"), (IMP)WXAIVCOnSheet, "v@:@");
    class_addMethod(cls, sel_registerName("onCustomDate:"), (IMP)WXAIVCOnCustomDate, "v@:@");
    class_addMethod(cls, sel_registerName("textFieldShouldReturn:"), (IMP)WXAIVCTFReturn, "c@:@@");
    objc_registerClassPair(cls);
    WXAIVCClass = cls;
}

// ============ 第2部分结束 ============
// 整合说明：将第1部分和第2部分用 cat 合并为 Tweak.x 即可编译
// 所有导出符号（WXRegisterChatVC, WXChatVCClass, WXRegisterStatsVC, WXStatsVCClass, WXStatsVCSetMode,
// WXRegisterAIVC, WXAIVCClass, WXAIVCSetInitialRange, WXAICallbackNative, WXAICBEmptyNative）
// 已在第2部分定义，与第1部分 extern 声明配对
// 所有 class_addMethod 追加到 WXUITargetCls 的方法（chatSearchChanged:, sheetDismiss:, sheetBtn:, dateSheetOk:, dateSheetCancel:）
// 已在 WXRegisterChatVC 中动态添加
