// WSClient.h — 最小 WebSocket 客户端（RFC6455 + permessage-deflate RFC7692）
// v7.1.55：edge-tts v2 实测要求 permessage-deflate（无压缩 iOS URLSessionWebSocketTask 合成阶段被断连 0 音频）
#import <Foundation/Foundation.h>

@interface WSClient : NSObject
- (instancetype)initWithURLString:(NSString *)urlString headers:(NSDictionary *)headers;
- (void)connect;
- (void)sendText:(NSString *)text;
- (void)close;
@property (nonatomic, copy) void (^onOpen)(void);
@property (nonatomic, copy) void (^onText)(NSString *text);
@property (nonatomic, copy) void (^onBinary)(NSData *data);
@property (nonatomic, copy) void (^onClose)(NSString *error);
@end
