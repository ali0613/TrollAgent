// WSClient.mm — 最小 WebSocket 客户端（RFC6455 客户端掩码帧 + permessage-deflate RFC7692）
// v7.1.55：edge-tts v2 实测要求 permessage-deflate 压缩协商；iOS URLSessionWebSocketTask 不支持压缩扩展
// → 合成阶段被服务器断连（Socket is not connected / audioBytes=0，用户 18:52/19:14/19:15 日志实锤）。
// 实现：NSStream TLS 连接 → HTTP Upgrade（Sec-WebSocket-Key/Accept 校验 + Sec-WebSocket-Extensions）→
// 帧收发（FIN/RSV/opcode/mask/len）→ RSV1=1 消息 zlib raw inflate 解压 → onText/onBinary 回调。
// 发送不压缩（permessage-deflate 逐方向独立，服务器不强求客户端压缩）。

#include <zlib.h>
#include <string.h>
#import <CFNetwork/CFNetwork.h>   // kCFStreamPropertySSLPeerName / kCFStreamSSLValidatesCertificateChain / CFStreamCreatePairWithSocketToHost
#import "WSClient.h"

@interface WSClient () <NSStreamDelegate>
@end

@implementation WSClient {
    NSString *_urlString;
    NSDictionary *_headers;
    NSInputStream *_in;
    NSOutputStream *_out;
    NSMutableData *_inBuf;      // 已读但未解析完的字节
    BOOL _handshakeDone;
    BOOL _handshakeSent;        // v7.1.61：握手请求已发送（OpenCompleted 发送）
    BOOL _closed;
    // 帧解析状态机
    BOOL _expectExtLen;
    uint64_t _payloadLen;
    int _payloadBytesRead;
    unsigned char _maskKey[4];
    BOOL _hasMask;
    uint8_t _opcode;
    uint8_t _finRsv;
    NSMutableData *_payloadBuf;
    int _inflateWindowBits;
    BOOL _serverDeflate;        // 服务端回 permessage-deflate
    NSString *_pendingHandshake;
    NSMutableArray *_sendQueue; // 握手完成前暂存待发文本
    uint8_t _msgOpcode;         // 当前消息起始帧 opcode（continuation 交付判定用）
}

- (instancetype)initWithURLString:(NSString *)urlString headers:(NSDictionary *)headers {
    self = [super init];
    if (self) {
        _urlString = urlString;
        _headers = headers ?: @{};
        _inBuf = [NSMutableData data];
        _payloadBuf = [NSMutableData data];
        _inflateWindowBits = 15;
        _sendQueue = [NSMutableArray array];
    }
    return self;
}

- (void)connect {
    NSURL *u = [NSURL URLWithString:_urlString];
    NSString *host = u.host;
    if (host.length == 0) { [self _fail:@"bad url host"]; return; }   // v7.1.59：NULL host 会崩 CF
    NSNumber *port = u.port ?: @443;
    CFReadStreamRef r = NULL; CFWriteStreamRef w = NULL;
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host, port.intValue, &r, &w);
    if (!r || !w) { [self _fail:@"socket create failed"]; return; }
    _in = (__bridge_transfer NSInputStream *)r;
    _out = (__bridge_transfer NSOutputStream *)w;
    [self _log:@"connect host=%@ port=%d streams=%@/%@", host, port.intValue, _in ? @"ok" : @"nil", _out ? @"ok" : @"nil"];
    // TLS：SNI + 校验证书链（bing 正规证书）。用字符串字面量（iOS 17.5 SDK 已移除
    // NSStreamSocketSecurityLevelTLSv1_2 / kCFStreamPropertySSLPeerName 等常量声明）。
    // 注意：value 直接是 SSLSettings 字典（PeerName/Validates），不能再套一层。
    NSDictionary *tlsSettings = @{
        @"kCFStreamSSLPeerName": host,
        @"kCFStreamSSLValidatesCertificateChain": @YES,
    };
    CFReadStreamSetProperty((__bridge CFReadStreamRef)_in, (__bridge CFStringRef)@"kCFStreamPropertySSLSettings", (__bridge CFDictionaryRef)tlsSettings);
    CFWriteStreamSetProperty((__bridge CFWriteStreamRef)_out, (__bridge CFStringRef)@"kCFStreamPropertySSLSettings", (__bridge CFDictionaryRef)tlsSettings);
    [self _log:@"TLS settings applied"];
    // v7.1.60：逐步行日志，精确定位 open 崩溃点
    _in.delegate = self; _out.delegate = self;
    [self _log:@"delegate set"];
    [_in scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [_out scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [self _log:@"scheduled, opening…"];
    [_in open];
    [self _log:@"in opened"];
    [_out open];
    [self _log:@"out opened, connect returns"];
    // 预构握手请求（含 permessage-deflate）
    NSString *path = [NSString stringWithFormat:@"%@?%@", u.path, u.query ?: @""];
    unsigned char keyBytes[16];
    for (int i = 0; i < 16; i++) keyBytes[i] = (unsigned char)arc4random_uniform(256);
    NSString *b64Key = [[NSData dataWithBytes:keyBytes length:16] base64EncodedStringWithOptions:0];
    NSMutableString *req = [NSMutableString string];
    [req appendFormat:@"GET %@ HTTP/1.1\r\n", path];
    [req appendFormat:@"Host: %@:%d\r\n", host, port.intValue];
    [req appendFormat:@"Connection: Upgrade\r\nUpgrade: websocket\r\n"];
    [req appendFormat:@"Sec-WebSocket-Key: %@\r\n", b64Key];
    [req appendFormat:@"Sec-WebSocket-Version: 13\r\n"];
    [req appendFormat:@"Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n"];
    [_headers enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        [req appendFormat:@"%@: %@\r\n", k, v];
    }];
    [req appendString:@"\r\n"];
    _pendingHandshake = [req copy];
    // v7.1.63：请求构造完立刻兜底尝试（此前在构造前调用=空转，只能依赖流事件）
    [self _sendHandshakeIfNeeded:_in];
    // v7.1.63：10 秒握手超时保护（事件不来直接报错，不永久卡死）
    __weak WSClient *wSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WSClient *s = wSelf;
        if (s && !s->_handshakeDone && !s->_closed) [s _fail:@"handshake timeout"];
    });
}

// v7.1.64：无条件入口日志 + write 未就绪时 200ms 自循环重试（彻底不依赖流事件）
- (void)_sendHandshakeIfNeeded:(NSStream *)aStream {
    [self _log:@"sendHandshake entry hs=%d pending=%d out=%@", _handshakeSent ? 1 : 0, _pendingHandshake ? 1 : 0, _out ? @"ok" : @"nil"];
    if (!_pendingHandshake) { [self _log:@"sendHandshake: pending=nil, skip"]; return; }
    if (_handshakeSent) { [self _log:@"sendHandshake: already sent, skip"]; return; }
    NSData *hd = [_pendingHandshake dataUsingEncoding:NSUTF8StringEncoding];
    [self _log:@"before write hd=%lu", (unsigned long)hd.length];
    NSInteger w = [_out write:(const uint8_t *)hd.bytes maxLength:hd.length];
    [self _log:@"after write w=%ld", (long)w];
    if (w > 0) {
        _handshakeSent = YES;
        [self _log:@"handshake sent %lu bytes (wrote %ld)", (unsigned long)hd.length, (long)w];
        if (w < (NSInteger)hd.length) [self _fail:@"handshake partial write"];
    } else {
        [self _log:@"handshake write pending (wrote %ld) — scheduling retry", (long)w];
        __weak WSClient *wSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WSClient *s = wSelf;
            if (s) [s _sendHandshakeIfNeeded:nil];
        });
    }
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    if (_closed) return;
    switch (eventCode) {
        case NSStreamEventOpenCompleted:
            [self _log:@"stream open completed"];
            [self _sendHandshakeIfNeeded:aStream];
            break;
        case NSStreamEventHasSpaceAvailable:
            [self _log:@"out stream has space"];
            [self _sendHandshakeIfNeeded:aStream];
            break;
        case NSStreamEventHasBytesAvailable: {
            if (!_handshakeDone) {
                // 先读握手响应
                uint8_t tmp[4096];
                NSInteger n = [_in read:tmp maxLength:sizeof(tmp)];
                [self _log:@"handshake read n=%ld", (long)n];
                if (n > 0) {
                    [_inBuf appendBytes:tmp length:n];
                    [self _tryFinishHandshake];
                }
            } else {
                uint8_t tmp[8192];
                NSInteger n = [_in read:tmp maxLength:sizeof(tmp)];
                [self _log:@"frame read n=%ld buf=%lu", (long)n, (unsigned long)_inBuf.length];
                if (n > 0) {
                    [_inBuf appendBytes:tmp length:n];
                    [self _processFrames];
                } else if (n == 0) {
                    [self _fail:@"stream closed"];
                }
            }
            break;
        }
        case NSStreamEventErrorOccurred: {
            NSError *e = aStream.streamError;
            [self _log:@"stream error: %@", e ? e.localizedDescription : @"unknown"];
            [self _fail:e ? e.localizedDescription : @"stream error"];
            break;
        }
        case NSStreamEventEndEncountered:
            [self _log:@"stream ended"];
            [self _fail:@"stream ended"];
            break;
        default:
            break;
    }
}

#pragma mark - 握手

- (void)_tryFinishHandshake {
    NSRange r = [_inBuf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, _inBuf.length)];
    if (r.location == NSNotFound) {
        if (_inBuf.length > 65536) [self _fail:@"handshake too large"];
        return;
    }
    NSData *headData = [_inBuf subdataWithRange:NSMakeRange(0, r.location + 4)];
    [_inBuf replaceBytesInRange:NSMakeRange(0, r.location + 4) withBytes:NULL length:0];
    NSString *head = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding];
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0 || ![lines[0] containsString:@"101"]) {
        [self _fail:[NSString stringWithFormat:@"bad status: %@", lines.firstObject]];
        return;
    }
    _serverDeflate = NO;
    for (NSString *line in lines) {
        if ([line.lowercaseString hasPrefix:@"sec-websocket-extensions:"]) {
            if ([line.lowercaseString containsString:@"permessage-deflate"]) {
                _serverDeflate = YES;
                // server_max_window_bits=NN 解析
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"server_max_window_bits=(\\d+)" options:0 error:nil];
                NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
                if (m && m.numberOfRanges > 1) {
                    int wb = [line substringWithRange:[m rangeAtIndex:1]].intValue;
                    if (wb >= 9 && wb <= 15) _inflateWindowBits = wb;
                }
            }
        }
    }
    _handshakeDone = YES;
    [self _log:@"handshake 101 OK deflate=%d", _serverDeflate ? 1 : 0];
    // 握手剩余字节（若有）当帧处理
    if (_inBuf.length > 0) [self _processFrames];
    // 握手完成：冲刷待发队列
    for (NSString *t in _sendQueue) [self sendText:t];
    [_sendQueue removeAllObjects];
    if (self.onOpen) self.onOpen();
}

#pragma mark - 帧解析（接收）

- (void)_processFrames {
    while (!_closed && _inBuf.length > 0) {
        // 帧头至少 2 字节
        if (_inBuf.length < 2) return;
        const uint8_t *b = (const uint8_t *)_inBuf.bytes;
        uint8_t b0 = b[0], b1 = b[1];
        _finRsv = b0;
        _opcode = b1 & 0x0F;
        _hasMask = (b1 & 0x80) != 0;
        uint64_t len = b1 & 0x7F;
        [self _log:@"frame opcode=%u len7=%llu fin=%d", _opcode, len, (_finRsv & 0x80) ? 1 : 0];
        NSUInteger headerLen = 2;
        if (len == 126) {
            if (_inBuf.length < 4) return;
            len = ((uint64_t)b[2] << 8) | b[3];
            headerLen = 4;
        } else if (len == 127) {
            if (_inBuf.length < 10) return;
            len = 0;
            for (int i = 0; i < 8; i++) len = (len << 8) | b[2 + i];
            headerLen = 10;
        }
        NSUInteger maskLen = _hasMask ? 4 : 0;
        NSUInteger need = headerLen + maskLen + (NSUInteger)len;
        if (_inBuf.length < need) return;
        NSUInteger off = headerLen;
        if (_hasMask) {
            memcpy(_maskKey, b + off, 4);
            off += 4;
        }
        NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)len];
        if (len > 0) {
            memcpy(payload.mutableBytes, b + off, (NSUInteger)len);
            if (_hasMask) {
                uint8_t *p = (uint8_t *)payload.mutableBytes;
                for (NSUInteger i = 0; i < len; i++) p[i] ^= _maskKey[i & 3];
            }
        }
        [_inBuf replaceBytesInRange:NSMakeRange(0, need) withBytes:NULL length:0];
        // 控制帧
        if (_opcode == 0x8) { [self _sendControl:0x8 payload:payload]; [self _fail:@"server closed"]; return; }       // close（回执再关）
        if (_opcode == 0x9) { [self _sendControl:0xA payload:payload]; continue; } // ping→pong
        if (_opcode == 0xA) continue;                                          // pong
        // 数据帧：text=1 / binary=2 / continuation=0
        if (_opcode == 0x1 || _opcode == 0x2 || _opcode == 0x0) {
            BOOL compressed = (_finRsv & 0x40) != 0;  // RSV1
            if (compressed && _serverDeflate) {
                NSData *raw = [self _inflate:payload];
                if (raw) payload = [NSMutableData dataWithData:raw];
                else { [self _fail:@"inflate failed"]; return; }
            }
            BOOL fin = (_finRsv & 0x80) != 0;
            if (_opcode == 0x1 || _opcode == 0x2) {
                _msgOpcode = _opcode;
                [_payloadBuf setLength:0];
                [_payloadBuf appendData:payload];
                if (fin) [self _deliverPayloadBuf];
            } else { // continuation
                [_payloadBuf appendData:payload];
                if (fin) [self _deliverPayloadBuf];
            }
        }
    }
}

- (void)_deliverPayloadBuf {
    if (_payloadBuf.length == 0) return;
    if (_msgOpcode == 0x1) {
        NSString *s = [[NSString alloc] initWithData:_payloadBuf encoding:NSUTF8StringEncoding];
        if (s && self.onText) self.onText(s);
    } else if (self.onBinary) {
        self.onBinary([_payloadBuf copy]);
    }
    [_payloadBuf setLength:0];
}

- (NSData *)_inflate:(NSData *)data {
    if (data.length == 0) return [NSData data];
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // raw deflate：windowBits = -inflateWindowBits
    if (inflateInit2(&strm, -_inflateWindowBits) != Z_OK) return nil;
    strm.next_in = (Bytef *)data.bytes;
    strm.avail_in = (uInt)data.length;
    NSMutableData *out = [NSMutableData data];
    uint8_t buf[16384];
    int ret;
    // v7.1.63：修复循环漏洞——输入未耗尽必须继续（旧版 avail_out>0 且 avail_in>0 时提前退出，大帧解压残缺）
    do {
        strm.next_out = buf;
        strm.avail_out = sizeof(buf);
        ret = inflate(&strm, Z_SYNC_FLUSH);
        if (ret == Z_NEED_DICT || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) {
            inflateEnd(&strm);
            return nil;
        }
        [out appendBytes:buf length:sizeof(buf) - strm.avail_out];
        if (ret == Z_STREAM_END) break;
    } while (strm.avail_in > 0);
    inflateEnd(&strm);
    // 剥掉尾部可能的 00 00 ff ff（部分实现输出残留）
    if (out.length >= 4) {
        const uint8_t *tail = (const uint8_t *)out.bytes + out.length - 4;
        if (tail[0] == 0x00 && tail[1] == 0x00 && tail[2] == 0xFF && tail[3] == 0xFF) {
            [out setLength:out.length - 4];
        }
    }
    return out;
}

#pragma mark - 发送

- (void)sendText:(NSString *)text {
    if (_closed) return;
    if (!_handshakeDone) { [_sendQueue addObject:text]; return; }  // 握手未完成先排队
    NSData *payload = [text dataUsingEncoding:NSUTF8StringEncoding];
    [self _sendFrame:0x1 payload:payload];
}

- (void)_sendControl:(uint8_t)opcode payload:(NSData *)payload {
    [self _sendRawFrame:opcode payload:payload masked:NO];
}

- (void)_sendFrame:(uint8_t)opcode payload:(NSData *)payload {
    [self _sendRawFrame:opcode payload:payload masked:YES];
}

- (void)_sendRawFrame:(uint8_t)opcode payload:(NSData *)payload masked:(BOOL)masked {
    NSMutableData *frame = [NSMutableData data];
    uint8_t b0 = 0x80 | opcode;  // FIN=1
    [frame appendBytes:&b0 length:1];
    uint8_t b1 = 0;
    NSUInteger len = payload.length;
    if (masked) b1 |= 0x80;
    if (len < 126) {
        b1 |= (uint8_t)len;
        [frame appendBytes:&b1 length:1];
    } else if (len <= 0xFFFF) {
        b1 |= 126;
        [frame appendBytes:&b1 length:1];
        uint16_t l = (uint16_t)len;
        uint8_t lh[2] = {(uint8_t)(l >> 8), (uint8_t)(l & 0xFF)};
        [frame appendBytes:lh length:2];
    } else {
        b1 |= 127;
        [frame appendBytes:&b1 length:1];
        uint8_t lh[8];
        uint64_t l64 = len;
        for (int i = 7; i >= 0; i--) { lh[i] = (uint8_t)(l64 & 0xFF); l64 >>= 8; }
        [frame appendBytes:lh length:8];
    }
    if (masked) {
        unsigned char key[4];
        for (int i = 0; i < 4; i++) key[i] = (unsigned char)arc4random_uniform(256);
        [frame appendBytes:key length:4];
        NSMutableData *maskedPayload = [NSMutableData dataWithLength:len];
        const uint8_t *src = (const uint8_t *)payload.bytes;
        uint8_t *dst = (uint8_t *)maskedPayload.mutableBytes;
        for (NSUInteger i = 0; i < len; i++) dst[i] = src[i] ^ key[i & 3];
        [frame appendData:maskedPayload];
    } else {
        [frame appendData:payload];
    }
    NSInteger wrote = [_out write:(const uint8_t *)frame.bytes maxLength:frame.length];
    if (wrote < (NSInteger)frame.length) {
        [self _log:@"frame write short: opcode=%u wrote=%ld/%lu", opcode, (long)wrote, (unsigned long)frame.length];
    }
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    [_in close]; [_out close];
    [_in removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [_out removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    _in = nil; _out = nil;
}

// v7.1.60：关键——对象释放前必须从 runloop 摘掉 stream。
// 之前 wc 在 _speakTTS 返回后被 ARC 释放，stream 悬空在 runloop 上 → EXC_BAD_ACCESS 闪退
- (void)dealloc {
    if (!_closed) [self close];
}

- (void)_fail:(NSString *)err {
    if (_closed) return;
    NSString *e = [err copy];
    [self _log:@"FAIL: %@", e];
    [self close];
    if (self.onClose) self.onClose(e);
}

// v7.1.65：直写 tts_debug.log（双通道，不依赖 onLog/VC 链路）——日志中断时仍有证据
- (void)_log:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *p = @"/var/mobile/Documents/tts_debug.log";
    NSString *entry = [NSString stringWithFormat:@"[ws] %@\n", line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [entry writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    if (self.onLog) self.onLog(line);
}

@end
