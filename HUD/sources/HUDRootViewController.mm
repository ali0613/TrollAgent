//
//  HUDRootViewController.mm
//  TrollAgent
//
//  悬浮窗内容：粉色萝莉塔小女孩（多帧动画 + 可拖动 + 点击换表情）
//  最小替代实现，替换 TrollSpeed 自带按钮球 UI。
//

#import "HUDRootViewController.h"
#import "HUDMainWindow.h"
#import <string.h>
#import <math.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <objc/runtime.h> // v6.1.5-8：真实 app 图标（TrollStore/TheBall 同款私有 API）
#import <dlfcn.h>       // v6.1.5-14b：点击打开 SBSLaunchApplicationWithIdentifier（运行时加载）

// v6.0.7：SpringBoardServices 是私有 framework（Xcode SDK 无头文件），直接 extern "C" 声明原型（.mm 是 C++，
// 不加 extern "C" 会按 C++ 链接找不到 tbd 里的 C 符号），符号由 HUD/libraries/SpringBoardServices.framework/SpringBoardServices.tbd 链接提供
extern "C" mach_port_t SBSSpringBoardServerPort(void);
extern "C" void SBGetScreenLockStatus(mach_port_t port, BOOL *isLocked, BOOL *isPasscodeSet);

// v6.0.7：锁屏保活（抄 TrollSpeed HUDRootViewController）——监听 springboard.lockstate，
// 锁屏时隐藏悬浮、解锁时恢复显示（进程本身是 posix_spawn 无沙盒 root 通常不被杀，窗口需锁屏隐藏/解锁恢复）
#define NOTIFY_UI_LOCKSTATE "com.apple.springboard.lockstate"

static BOOL _passthrough = NO;

@interface HUDRootViewController ()
- (void)lockHide;
- (void)unlockShow;
- (void)registerNotifications;
- (void)_appendHudLog:(NSString *)line; // v6.1.5-7：诊断日志写 /tmp/hud_fan.log
@end

// v6.0.8：裁剪掉 UIImage 四周透明留白，返回角色实际内容图（无背景留白，角色才能贴到屏幕边缘）。
// 读像素检测不透明(alpha)边界，用 CGImageCreateWithImageInRect 裁出内容矩形。
static UIImage * _trimTransparentPadding(UIImage *img) {
    if (!img || !img.CGImage) return img;
    CGImageRef cg = img.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return img;
    size_t bpr = w * 4;
    unsigned char *px = (unsigned char *)calloc(h, bpr);
    if (!px) return img;
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, bpr, CGImageGetColorSpace(cg),
                                             kCGImageAlphaPremultipliedLast);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        int minX = (int)w, maxX = -1, minY = (int)h, maxY = -1;
        for (size_t y = 0; y < h; y++) {
            const unsigned char *row = px + y * bpr;
            for (size_t x = 0; x < w; x++) {
                if (row[x * 4 + 3] > 8) {   // alpha > 阈值为内容
                    int ix = (int)x, iy = (int)y;
                    if (ix < minX) minX = ix;
                    if (ix > maxX) maxX = ix;
                    if (iy < minY) minY = iy;
                    if (iy > maxY) maxY = iy;
                }
            }
        }
        CGContextRelease(ctx);
        if (maxX >= minX && maxY >= minY &&
            (minX > 0 || minY > 0 || maxX < (int)w - 1 || maxY < (int)h - 1)) {
            CGRect r = CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
            CGImageRef crop = CGImageCreateWithImageInRect(cg, r);
            if (crop) {
                img = [UIImage imageWithCGImage:crop scale:img.scale orientation:img.imageOrientation];
                CGImageRelease(crop);
            }
        }
    }
    free(px);
    return img;
}


// 锁屏状态回调（TrollSpeed 正解）：锁屏隐藏悬浮视图，解锁恢复显示
static void SpringBoardLockStatusChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    HUDRootViewController *vc = (__bridge HUDRootViewController *)observer;
    NSString *lockState = (__bridge NSString *)name;
    if ([lockState isEqualToString:@NOTIFY_UI_LOCKSTATE]) {
        mach_port_t sbsPort = SBSSpringBoardServerPort();
        if (sbsPort == MACH_PORT_NULL) return;
        BOOL isLocked = NO, isPasscodeSet = NO;
        SBGetScreenLockStatus(sbsPort, &isLocked, &isPasscodeSet);
        if (!isLocked) [vc unlockShow];
        else [vc lockHide];
    }
}

// v6.0.7：悬浮小女孩显示尺寸（pt），由主 App 启动时 -size N 传入（HUDMain.mm 解析），默认 150
extern "C" double g_hud_size;
// v6.0.7：悬浮角色（girl=小萝莉 / rabit=兔娘），由主 App 启动时 -char 传入（HUDMain.mm 解析）
extern "C" const char *g_hud_char;

@implementation HUDRootViewController {
    UIImageView *_girlView;
    NSArray<UIImage *> *_idleFrames;
    NSArray<UIImage *> *_happyFrames;
    NSArray<UIImage *> *_thinkFrames;
    UIImage *_wallImage;      // v6.0.8：扒墙姿势图（水平墙沿——顶/底边缘）
    UIImage *_wallImageV;     // v6.0.8：扒墙姿势图（竖直墙沿——左/右边缘）
    NSArray<UIImage *> *_moodFrames;  // v6.0.8：更多站立表情/动作帧（blink/wave/tilt/giggle/heart/surprise/angry/jump）
    BOOL _autoMoodPaused;             // 锁屏时暂停待机自动换表情
    BOOL _moodShowing;                // 待机表情显示中（防重复切换）
    BOOL _isDragging;
    BOOL _isHidden;
    CGPoint _dragOffset;
    NSUInteger _moodSeqIndex;  // v6.0.9：待机有序循环当前帧序号（不再随机挑帧）
    CGFloat _charScale;        // v6.0.12：角色站姿放大系数（rabit 1.4 / cat 1.2 / girl 1.0）
    NSArray<UIImage *> *_liftFrames;   // v6.0.12：拖起悬空挣扎帧（lift1/lift2，拖拽时交替显示）
    NSArray<UIImage *> *_squatFrames;  // v6.0.12：蹲坐/跪姿帧集合（显示时按站姿缩小）
    BOOL _lifting;             // 正在拖起悬空显示中
    NSTimer *_liftTimer;       // 悬空挣扎交替计时器
    int _liftIdx;              // 悬空帧交替序号
    CGFloat _dragHalfW, _dragHalfH;   // v6.0.21：拖拽时帧的半宽/半高（吸附判定用拖拽帧尺寸，避免恢复待机后窄帧误判不贴边）
    CGFloat _snapReachH, _snapReachV;  // v6.0.27：吸附距离按角色独立配置（左右/上下），与 lift 帧尺寸解耦——调 charScale/素材不再破坏吸附
    BOOL _enableChest;         // v6.0.24：是否启用胸部呼吸动效（仅兔娘 rabit / 猫娘 cat，萝莉 girl 不做）
    BOOL _isCatChar;           // v6.0.25：当前角色是猫娘（身材最修长，胸乳位置更高，用于胸部动效定位）
    CALayer *_chestLayer;   // v6.0.21：左胸呼吸层（mask 只显示左胸条带，心跳式脉冲鼓起，不再整身缩放）
    CALayer *_chestLayerR;  // v6.0.23：右胸呼吸层（mask 只显示右胸条带，与左胸同步脉冲）
    UIImage *_fallImage;        // v6.0.25：松手掉落帧
    BOOL _falling;              // 正在掉落动画中
    NSArray<UIImage *> *_climbFrames;  // v6.0.26：爬墙帧（左右边缘自动攀爬）
    BOOL _isClimbing;           // 正在攀爬中
    NSTimer *_climbTimer;        // 攀爬交替计时器
    NSTimer *_climbSchedTimer;  // v6.1.5-14x：攀爬延迟排期定时器（可取消，替代不可取消的 dispatch_after——防止反复吸附堆积多个攀爬任务）
    int _climbIdx;              // 攀爬帧序号
    UILabel *_bubbleLabel;       // v6.0.27：侧边趴墙卡通聊天气泡文字
    UIView *_bubbleView;         // v6.0.28：卡通气泡背景（带小尾巴）
    CAShapeLayer *_bubbleTailLayer;  // v6.1.5-14ah：气泡尖角（画在父视图绕开 masksToBounds 裁剪）
    NSTimer *_bubbleTimer;       // 气泡定时弹出计时器
    BOOL _onSideWall;           // 是否在左右侧边趴墙
    BOOL _onBottomWall;         // v6.1.5-14w：是否底部趴墙（底部呼吸/横向挪动专用）
    NSTimer *_bottomCrawlTimer; // v6.1.5-14w：底部横向挪动定时器
    NSTimer *_autoMoodTimer;    // v6.1.5-14y：待机表情排期定时器（可取消，防解锁/回前台多链堆积）
    NSTimer *_autoMoodResetTimer; // v6.1.5-14y：表情显示1.2s后回待机的定时器
    NSTimer *_poseShowTimer;    // v6.1.5-14z：吸附态偶尔换姿势展示排期（1小时3-5次）
    NSTimer *_poseHoldTimer;    // v6.1.5-14z：姿势展示保持计时（2.5-3s后趴回）
    BOOL _poseShowing;          // v6.1.5-14z：正在展示站立/坐姿（展示中不触发攀爬/挪动）
    NSArray<UIColor *> *_particleColors; // v6.1.5-14aa：粒子颜色持有（cell.color 是 assign 语义，防局部数组释放后 CGColor 悬垂）
    NSString *_charPrefix;      // v6.0.27：当前角色前缀（rabit/girl/cat）
    NSInteger _lastFanClickIdx;         // v6.1.5-14i：菜单点击去重（手势+按钮双触发只处理一次）
    NSTimeInterval _lastFanClickTime;   // v6.1.5-14i
    NSTimer *_kbTimer;                  // v6.1.5-14n：键盘全局文件轮询
    CGFloat _dragLastX, _dragLastY;     // v6.1.5-14o：拖拽倾斜速度基准
    CAEmitterLayer *_particleLayer;     // v6.1.5-14p：氛围粒子层（闪电/萤火虫/星星/zZ）
    NSTimer *_ambientTimer;             // v6.1.5-14p：环境氛围定时器（60s 检查小时+充电态）
    NSInteger _ambientBucket;           // v6.1.5-14p：当前环境时段桶（-1初始/0白天/1傍晚/2深夜/3充电）——变化才重置漂浮
}

+ (BOOL)passthroughMode { return _passthrough; }
+ (void)setPassthroughMode:(BOOL)enabled { _passthrough = enabled; }

- (instancetype)init {
    if (self = [super init]) {
        // v6.0.7：按当前角色加载多帧图（girl_小萝莉 / rabit_兔娘 / cat_猫娘，HUD bundle 内）
        // v6.0.11：新增 cat 猫娘——21 帧动作集与 girl 同构（睁眼段→眯眼段→蹲坐段），moodNames 并集已覆盖全部帧名
        BOOL isCat = (g_hud_char && strcmp(g_hud_char, "cat") == 0);
        BOOL isRabbit = (g_hud_char && strcmp(g_hud_char, "rabit") == 0);
        NSString *prefix = isCat ? @"cat" : (isRabbit ? @"rabit" : @"girl");
        _charPrefix = prefix;   // v6.0.27：保存角色前缀，用于气泡文案
        // v6.0.12：兔娘/猫娘身高修长，站姿放大到与萝莉【视觉面积相等】（同高150下内容宽：萝莉73/猫60/兔52，
        // 用 s 放大后包围盒面积≈1.1万：rabit s=1.4(H210/W52)、cat s=1.2(H180/W60)、girl s=1.0(H150/W73)，三者面积差<1%）
        _charScale = isRabbit ? 1.2f : (isCat ? 1.3f : 1.0f);   // v6.0.30：猫娘1.3 高于 兔娘1.2 高于 萝莉1.0
        // v6.0.27：吸附距离按角色独立配置——该分开就分开（每角色独立值，可单独微调），与 lift 帧尺寸解耦；
        // 值为"角色中心到边缘触发吸附的距离"，已含内容留白容差，调 charScale/素材不影响吸附判定
        if (isCat)         { _snapReachH = 78.0f; _snapReachV = 92.0f; }   // 猫娘吸附位置不变，保持原阈值
        else if (isRabbit) { _snapReachH = 68.0f; _snapReachV = 80.0f; }   // 兔娘(1.2)
        else               { _snapReachH = 58.0f; _snapReachV = 68.0f; }   // 萝莉(1.0)
        _enableChest = (isCat || isRabbit);   // v6.0.24：胸部呼吸仅兔娘/猫娘（萝莉 girl 不做）
        _isCatChar = isCat;                   // v6.0.25：标记猫娘（胸乳位置更高）
        UIImage *idle  = [UIImage imageNamed:[NSString stringWithFormat:@"%@_idle", prefix]];
        UIImage *happy = [UIImage imageNamed:[NSString stringWithFormat:@"%@_happy", prefix]];
        UIImage *think = [UIImage imageNamed:[NSString stringWithFormat:@"%@_think", prefix]];
        UIImage *talk  = [UIImage imageNamed:[NSString stringWithFormat:@"%@_talk", prefix]];
        if (idle)  _idleFrames  = @[_trimTransparentPadding(idle)];
        if (happy) _happyFrames = @[_trimTransparentPadding(happy)];
        if (think) _thinkFrames = @[_trimTransparentPadding(think)];
        if (talk)  _thinkFrames = @[_trimTransparentPadding(talk)];   // 说话帧暂并入 think 备用
        UIImage *wall = [UIImage imageNamed:[NSString stringWithFormat:@"%@_wall", prefix]];
        if (wall) _wallImage = _trimTransparentPadding(wall);   // v6.0.8：水平扒墙（顶/底边缘）
        UIImage *wallV = [UIImage imageNamed:[NSString stringWithFormat:@"%@_wall_v", prefix]];
        if (wallV) _wallImageV = _trimTransparentPadding(wallV);   // v6.0.8：竖直扒墙（左/右边缘）
        // v6.0.12：拖起悬空挣扎帧（lift1/lift2）——拖拽角色时交替显示"被凭空提起、双手双腿挣扎"
        NSMutableArray *lifts = [NSMutableArray array];
        for (int li = 1; li <= 2; li++) {
            UIImage *lf = [UIImage imageNamed:[NSString stringWithFormat:@"%@_lift%d", prefix, li]];
            if (lf) [lifts addObject:_trimTransparentPadding(lf)];
        }
        if (lifts.count) _liftFrames = lifts;
        // v6.0.25：松手掉落帧
        UIImage *fall = [UIImage imageNamed:[NSString stringWithFormat:@"%@_fall", prefix]];
        if (fall) _fallImage = _trimTransparentPadding(fall);
        // v6.0.26：爬墙帧（左右边缘自动攀爬）
        NSMutableArray *climbs = [NSMutableArray array];
        for (int ci = 1; ci <= 2; ci++) {
            UIImage *cf = [UIImage imageNamed:[NSString stringWithFormat:@"%@_climb%d", prefix, ci]];
            if (cf) [climbs addObject:_trimTransparentPadding(cf)];
        }
        if (climbs.count) _climbFrames = climbs;
        // v6.0.9：待机动作改为【有序循环】（用户要求：睁眼idle放第一 → 眯眼微笑帧穿插在睁眼后面 → 下蹲/坐姿 → 回睁眼，循环），不再随机挑帧。
        // 顺序即播放顺序：睁眼段(站立睁眼表情) → 眯眼段(闭眼微笑/弯月眼) → 蹲坐段(蹲/跪/坐/趴姿势)，播完回 idle 再从头循环。
        NSArray *moodNames = @[
            @"tilt", @"heart", @"surprise", @"angry", @"jump",      // 睁眼段
            @"blink", @"giggle", @"wave",                           // 眯眼段
            @"squat", @"kneel", @"sit", @"side", @"hands", @"cross", @"lift",
            @"wave_sit", @"kneel_up", @"side_sit", @"squat_hold", @"prone", @"chin_sit"   // 蹲坐段
        ];
        NSMutableArray *mood = [NSMutableArray array];
        NSArray *squatNames = @[@"squat", @"kneel", @"sit", @"side", @"hands", @"cross", @"lift",
                                @"wave_sit", @"kneel_up", @"side_sit", @"squat_hold", @"prone", @"chin_sit"];
        NSMutableArray *squats = [NSMutableArray array];
        for (NSString *mn in moodNames) {
            UIImage *m = [UIImage imageNamed:[NSString stringWithFormat:@"%@_%@", prefix, mn]];
            if (m) {
                // Bug修复：裁剪只做一次，mood 与 squats 共用同一个 UIImage 对象。
                // 不能两次分别调 _trimTransparentPadding——那会产出两个不同实例；UIImage 未重写 isEqual（按指针比较），
                // 导致 _setFrameForImage 里 [_squatFrames containsObject:img] 永远 NO、蹲坐缩小完全不生效。
                UIImage *t = _trimTransparentPadding(m);
                [mood addObject:t];
                // v6.0.12：蹲坐/跪姿帧单独分组（复用 mood 里同一对象），显示时按站姿缩小
                if ([squatNames containsObject:mn]) [squats addObject:t];
            }
        }
        if (squats.count) _squatFrames = squats;
        if (mood.count) _moodFrames = mood;
        if (!idle) {
            // 兜底：纯色圆（资源缺失时仍可见）
            _idleFrames = @[ [self _placeholderCircle] ];
        }
    }
    return self;
}

- (UIImage *)_placeholderCircle {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(120, 120), NO, 0);
    [[UIColor systemPinkColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 120, 120)] fill];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    _girlView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _girlView.image = _idleFrames.firstObject;
    _girlView.contentMode = UIViewContentModeScaleAspectFit;
    _girlView.userInteractionEnabled = YES;
    [self.view addSubview:_girlView];

    CGFloat size = (CGFloat)g_hud_size * _charScale;   // 悬浮角色显示尺寸（v6.0.7 可调默认150；v6.0.12 乘角色放大系数：兔娘1.4/猫娘1.2）
    // v6.0.8：高固定 size、宽按裁剪后角色内容比例——aspectFit 填满、左右不留白，角色才能真正贴到屏幕边缘
    UIImage *idleImg = _idleFrames.firstObject;
    CGFloat aspect = (idleImg.size.height > 0) ? (idleImg.size.width / idleImg.size.height) : 1.0;
    CGFloat w = size * aspect;
    _girlView.frame = CGRectMake((self.view.bounds.size.width - w)/2,
                                 (self.view.bounds.size.height - size)/2,
                                 w, size);
    // 初始锚点=中心(0.5)，不偏移；胸部呼吸锚点(0.42)按状态在 _startBreathing 切换，趴墙/拖拽悬浮保持中心

    // v6.0.30：键盘弹出时自动隐藏桌宠，默认打开
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"autoHideWithKeyboard"] == nil) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"autoHideWithKeyboard"];
    }
    // 全局监听键盘，兜底4个通知，确保能收到
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardDidShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardDidHideNotification object:nil];

    // v6.0.7：注册锁屏/解锁监听（锁屏隐藏悬浮、解锁恢复，抄 TrollSpeed）
    [self registerNotifications];

    // v6.1.5-14n：键盘轮询——独立 HUD 收不到其他 App 的键盘通知，
    // 由主 App 写 /var/mobile/Documents/keyboard_state.json，HUD 每 0.5s 轮询应用
    _kbTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_pollKeyboardFile) userInfo:nil repeats:YES];

    // v6.1.5-14p：环境氛围——粒子（充电闪电/深夜萤火虫星星/入睡zZ）+ 昼夜光影（月光/暖光）
    [self _setupAmbient];

    // 呼吸动画（idle 缩放循环）
    [self _startBreathing];

    // v6.0.8：待机自动切换表情（空闲时随机眨眼/挥手/歪头等）
    [self _scheduleAutoMood];

    // 拖动 + 点击
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_pan:)];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap:)];
    [_girlView addGestureRecognizer:pan];
    [_girlView addGestureRecognizer:tap];
    // v6.1.5-14o：活物感——双击=蹦跳开心、长按=捏扁弹回（单击=弹菜单，互不冲突）
    UITapGestureRecognizer *tap2 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_doubleTap:)];
    tap2.numberOfTapsRequired = 2;
    [_girlView addGestureRecognizer:tap2];
    [tap requireGestureRecognizerToFail:tap2];  // 双击时不触发单击
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_longPress:)];
    lp.minimumPressDuration = 0.4;
    [_girlView addGestureRecognizer:lp];
    [tap requireGestureRecognizerToFail:lp];    // 长按时不触发单击
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 窗口全屏，内容透明
    self.view.frame = [UIScreen mainScreen].bounds;
}

// v6.0.7：上下漂浮动画（原来呼吸缩放改成上下飘——用户要求对齐 app 里的漂浮效果）
// v6.0.8：改 CABasicAnimation（layer 级）——UIView animateWithDuration 的 block 在锁屏/解锁的
// runloop 状态下可能不执行，导致解锁后悬浮在但不浮动；CABasicAnimation 直接操作 layer 更稳。
// v6.0.18：按状态切换缩放锚点——待机呼吸用胸部锚点(0.42,呼吸以胸口为轴心)，趴墙/拖拽悬浮用中心锚点(0.5,保持原定位)。
// 切换时补偿 position，保证几何中心视觉位置不变、不跳动。
- (void)_setAnchorY:(CGFloat)ay {
    CGFloat cur = _girlView.layer.anchorPoint.y;
    if (fabs(cur - ay) < 0.001) return;
    _girlView.layer.anchorPoint = CGPointMake(0.5, ay);
    _girlView.center = CGPointMake(_girlView.center.x, _girlView.center.y + (ay - cur) * _girlView.bounds.size.height);
}

- (void)_startBreathing {
    [_girlView.layer removeAllAnimations];   // 防重复调用叠加动画
    [self _setAnchorY:0.5f];   // v6.0.21：整身不再缩放，锚点回归中心（胸部呼吸改用独立胸部条带层）
    [self _startFloatWithDuration:1.3f];   // v6.0.21：待机漂浮放慢回原速(单程1.3s)——用户:站立太快,原先慢速就很好
    // v6.0.21：胸部局部呼吸动效——独立胸部条带层 scale，只有胸口鼓起、身体其他部分不动（不再整身缩放）
    [self _startChestBreath];
}

// v6.0.21：上下漂浮统一入口——待机用慢速(单程1.3s)，悬浮/拖拽用快速(0.5s)
- (void)_startFloatWithDuration:(CGFloat)dur {
    [_girlView.layer removeAnimationForKey:@"hudFloat"];
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    anim.fromValue = @(0);
    anim.toValue = @(-14);
    anim.duration = dur;
    anim.autoreverses = YES;
    anim.repeatCount = INFINITY;
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_girlView.layer addAnimation:anim forKey:@"hudFloat"];
}

// v6.0.21：胸部呼吸动效——两胸分别做"快速鼓一下-缩回"的心跳式脉冲（用户要求：两胸、放大镜一下一下）。
// v6.0.24：仅兔娘/猫娘（萝莉不做）、仅站立姿势触发；位置对准胸乳（原0.42落到肚子/腰），mask 改【圆形径向渐变柔边】（不再方形切割感）。
- (void)_startChestBreath {
    [_chestLayer removeFromSuperlayer]; _chestLayer = nil;
    [_chestLayerR removeFromSuperlayer]; _chestLayerR = nil;
    if (!_enableChest || !_girlView.image) return;
    // v6.1.5-14t：防御——趴墙/攀爬态不启动胸前特效（用户反馈"侧边栏也会出现胸前特效"）
    if (_onSideWall || _isClimbing) return;
    if (_girlView.image == _wallImage || _girlView.image == _wallImageV) return;
    CGFloat W = _girlView.bounds.size.width;
    CGFloat H = _girlView.bounds.size.height;
    if (W < 1 || H < 1) return;
    // v6.0.25：胸乳位置按角色——兔娘身材修长胸乳≈35%；猫娘最修长(1.4)胸乳更高≈30%（原0.35对猫娘仍落到肚子）
    // v6.0.27：猫娘胸乳瞄点修正——猫娘窄身(内容宽仅0.49W)，原0.32/0.68水平对称导致右胸0.68W落在手臂、间距0.36W偏大；
    // 按 cat_idle 像素实测：左胸≈0.40W、右胸≈0.60W（间距0.20W）、右胸略高(0.28H vs 左0.30H，姿态右肩微抬)
    CGFloat r = H * 0.075f;            // 胸乳圆半径（圆形柔边直径=0.15H）
    CGFloat xL, xR, cyL, cyR;
    if (_isCatChar) {
        xL = W * 0.40f;  xR = W * 0.60f;
        cyL = H * 0.30f; cyR = H * 0.28f;
    } else {
        xL = W * 0.32f;  xR = W * 0.68f;   // 兔娘保持原瞄点
        cyL = cyR = H * 0.35f;
    }
    // 左胸 / 右胸（各自圆形柔边 mask，缩放锚点=各自胸乳圆心）
    _chestLayer  = [self _makeChestLayer:CGPointMake(xL, cyL) radius:r];
    [_chestLayer  addAnimation:[self _chestPulse] forKey:@"chestScale"];
    _chestLayerR  = [self _makeChestLayer:CGPointMake(xR, cyR) radius:r];
    [_chestLayerR addAnimation:[self _chestPulse] forKey:@"chestScale"];
}

// v6.0.24：创建单个胸部脉冲层——contents 铺满 bounds，mask 为【圆形径向渐变柔边】（中心黑不透明→边缘渐变透明），
// 缩放锚点=胸乳圆心、position 补偿使层仍铺满 bounds；scale 时只把圆内胸乳内容鼓起，边缘柔和无方形切割。
- (CALayer *)_makeChestLayer:(CGPoint)center radius:(CGFloat)r {
    CGFloat W = _girlView.bounds.size.width;
    CGFloat H = _girlView.bounds.size.height;
    CALayer *cl = [CALayer layer];
    cl.frame = _girlView.bounds;
    cl.contents = (id)_girlView.image.CGImage;
    cl.contentsGravity = kCAGravityResizeAspect;
    CGFloat d = r * 2;
    CALayer *mask = [CALayer layer];
    mask.frame = CGRectMake(center.x - r, center.y - r, d, d);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(d, d), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[8] = {0,0,0,1, 0,0,0,0};   // 黑(不透明)→透明
    CGFloat locs[2] = {0, 1};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    CGContextDrawRadialGradient(ctx, g, CGPointMake(d/2, d/2), r*0.35f, CGPointMake(d/2, d/2), r, 0);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    mask.contents = (id)img.CGImage;
    CGColorSpaceRelease(cs); CGGradientRelease(g); UIGraphicsEndImageContext();
    cl.mask = mask;
    cl.anchorPoint = CGPointMake(center.x / W, center.y / H);
    cl.position = center;   // 使层仍铺满 bounds（frame.origin 归零）
    [_girlView.layer addSublayer:cl];
    return cl;
}

// v6.0.23：心跳式脉冲——快速鼓起到1.12、快速缩回，停顿后循环（放大镜一下一下）
- (CAKeyframeAnimation *)_chestPulse {
    CAKeyframeAnimation *b = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    b.values = @[@1.0f, @1.12f, @1.0f, @1.0f];
    b.keyTimes = @[@0.0f, @0.14f, @0.32f, @1.0f];
    b.duration = 0.6;
    b.repeatCount = INFINITY;
    b.calculationMode = kCAAnimationCubic;
    return b;
}

- (void)_stopChestBreath {
    [_chestLayer removeFromSuperlayer]; _chestLayer = nil;
    [_chestLayerR removeFromSuperlayer]; _chestLayerR = nil;
}

// v6.0.9：待机自动切换表情——空闲时按 _moodFrames【顺序循环】取一帧显示约 1.2s（睁眼→眯眼→蹲坐→回睁眼），然后回 idle，再排下一次。
// 只在"待机态 + 未拖拽 + 未扒墙 + 未锁屏"时切换，不打断用户正在看的表情/扒墙/拖拽。
// v6.1.5-14y：dispatch_after → 可取消定时器——原实现 unlockShow/启动/递归多入口排多个 4.5s 延迟，
// 频繁锁屏/解锁会堆积多链并行导致表情乱切；现在排期全局唯一（新排期 invalidate 旧的）
- (void)_scheduleAutoMood {
    if (!_moodFrames.count || _moodShowing) return;
    [_autoMoodTimer invalidate];
    _autoMoodTimer = nil;
    _autoMoodTimer = [NSTimer scheduledTimerWithTimeInterval:4.5
                                                      target:self
                                                    selector:@selector(_autoMoodFire)
                                                    userInfo:nil repeats:NO];
}
- (void)_autoMoodFire {
    _autoMoodTimer = nil;
    if (_autoMoodPaused || _isDragging || _falling || _isHidden || _moodShowing) { [self _scheduleAutoMood]; return; }  // v6.1.5-14ab/ad：掉落/隐藏中不切表情
    if (_girlView.image == _wallImage || _girlView.image == _wallImageV) { [self _scheduleAutoMood]; return; }
    if (_girlView.image != _idleFrames.firstObject) { [self _scheduleAutoMood]; return; }
    NSUInteger idx = _moodSeqIndex % _moodFrames.count;
    _moodSeqIndex = (_moodSeqIndex + 1) % _moodFrames.count;
    UIImage *m = _moodFrames[idx];
    if (!m) { [self _scheduleAutoMood]; return; }
    _moodShowing = YES;
    _girlView.image = m;
    [self _setFrameForImage:m];
    // v6.1.5-14o：偷偷小动作——头顶冒 emoji 小符号（😊✨🥱😋🌟），活物感
    NSArray *emojis = @[@"😊", @"✨", @"🥱", @"😋", @"🌟"];
    [self _showHeadEmoji:emojis[arc4random_uniform((uint32_t)emojis.count)]];
    // 显示 1.2s 后回待机（可取消定时器）
    [_autoMoodResetTimer invalidate];
    _autoMoodResetTimer = nil;
    _autoMoodResetTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                           target:self
                                                         selector:@selector(_autoMoodReset)
                                                         userInfo:nil repeats:NO];
}
- (void)_autoMoodReset {
    _autoMoodResetTimer = nil;
    _moodShowing = NO;
    if (!_isDragging && !_autoMoodPaused &&
        _girlView.image != _idleFrames.firstObject &&
        _girlView.image != _wallImage && _girlView.image != _wallImageV) {
        _girlView.image = _idleFrames.firstObject;
        _girlView.transform = CGAffineTransformIdentity;
        [self _setFrameForImage:_idleFrames.firstObject];
    }
    [self _scheduleAutoMood];
}

// v6.0.7：注册 springboard 锁屏状态监听（抄 TrollSpeed HUDRootViewController）
- (void)registerNotifications {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, (__bridge const void *)self, SpringBoardLockStatusChanged, CFSTR(NOTIFY_UI_LOCKSTATE), NULL, CFNotificationSuspensionBehaviorCoalesce);
}

// 锁屏：隐藏悬浮 + 停止动画
- (void)lockHide {
    _girlView.hidden = YES;
    _autoMoodPaused = YES;
    _moodShowing = NO;
    [_autoMoodTimer invalidate]; _autoMoodTimer = nil;          // v6.1.5-14y：锁屏停表情排期
    [_autoMoodResetTimer invalidate]; _autoMoodResetTimer = nil;
    [self _stopPoseShow];   // v6.1.5-14z：锁屏打断坐姿/跪姿展示
    [_girlView.layer removeAllAnimations];
}

// 解锁：恢复显示 + 重启动画
- (void)unlockShow {
    _girlView.hidden = NO;
    _autoMoodPaused = NO;
    [self _startBreathing];
    [self _scheduleAutoMood];
}

// 拖动悬浮小女孩
- (void)_pan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    if (g.state == UIGestureRecognizerStateBegan) {
        _isDragging = YES;
        if (_isHidden) { _isHidden = NO; self.view.alpha = 1.0; }   // v6.1.5-14ad：隐藏态拖拽即恢复显示（否则 0.1 小点被拖走还残留隐藏标志）
        _dragLastX = 0; _dragLastY = 0;  // v6.1.5-14o：拖拽倾斜速度基准重置
        [self _stopClimbTimer];    // v6.0.29：拖动时立刻停止所有攀爬
        [self _stopBottomAmbient]; // v6.1.5-14w：拖动时停止底部呼吸/横向挪动
        [self _stopPoseShow];      // v6.1.5-14z：拖动时打断坐姿/跪姿展示（排期一并作废）
        [self _setAnchorY:0.5f];   // v6.0.18：拖拽/悬浮→中心锚点（悬浮不做胸部锚点）
        [self _stopChestBreath];   // v6.0.21：拖拽/悬浮停胸部呼吸（移除条带层）
        [self _startFloatWithDuration:0.5f];   // v6.0.21：悬浮/拖拽上下浮动加快到0.5s单程
        _dragOffset = CGPointMake(p.x - _girlView.center.x, p.y - _girlView.center.y);
        // v6.0.12：拖起角色→显示"被凭空提起、挣扎"悬空帧（lift1/lift2 交替），不再一直显示待机
        if (_liftFrames.count) {
            [self _stopLiftTimer];   // v6.0.21：先停旧定时器（其内部会置 _lifting=NO），避免覆盖下面的悬空态——这是悬空帧从不交替的根因
            _lifting = YES; _liftIdx = 0;
            _girlView.image = _liftFrames.firstObject;
            _girlView.transform = CGAffineTransformIdentity;
            [self _setFrameForImage:_liftFrames.firstObject];
            _liftTimer = [NSTimer timerWithTimeInterval:0.18 target:self selector:@selector(_liftTick) userInfo:nil repeats:YES];
            // v6.0.19：加入 CommonModes——scheduledTimer 默认在 default mode，拖拽时 runloop 切 UITrackingRunLoopMode
            // 定时器不触发，悬空帧永不交替(一直显示 lift1)。CommonModes 让 tracking 下也能交替。
            [[NSRunLoop mainRunLoop] addTimer:_liftTimer forMode:NSRunLoopCommonModes];
        } else if (_girlView.image != _idleFrames.firstObject && _idleFrames.firstObject) {
            // 无悬空帧：从吸附/扒墙状态开始拖动，先恢复待机图
            _girlView.image = _idleFrames.firstObject;
            _girlView.transform = CGAffineTransformIdentity;
            [self _setFrameForImage:_idleFrames.firstObject];
        }
    } else if (g.state == UIGestureRecognizerStateChanged && _isDragging) {
        CGPoint c = CGPointMake(p.x - _dragOffset.x, p.y - _dragOffset.y);
        // v6.0.8: 边界用屏幕尺寸（不依赖可能非全屏的 self.view.bounds）——确保能拖到屏幕右/下边缘
        CGSize v = [UIScreen mainScreen].bounds.size;
        // v6.0.7 修复：边界用显示尺寸（frame.size）而非图片固有尺寸（bounds 是 600×900）——
        // 旧代码用 bounds 导致角色拖不到屏幕边缘。改用 frame 后角色可紧贴屏幕边。
        CGSize gs = _girlView.frame.size;
        _dragHalfW = gs.width/2; _dragHalfH = gs.height/2;   // v6.0.21：记录拖拽帧半尺寸，吸附判定据此（贴边钳制就是拖拽帧半宽）
        c.x = MAX(gs.width/2, MIN(c.x, v.width - gs.width/2));
        c.y = MAX(gs.height/2, MIN(c.y, v.height - gs.height/2));
        _girlView.center = c;
        [self _refreshAmbientPosition];   // v6.1.5-14ac：拖拽中粒子跟随角色（原只在松手后更新，拖拽时粒子脱节）
        // v6.1.5-14o：活物感——拖拽时朝移动方向微微倾斜（速度越大倾角越大，像被拽着挣扎）
        CGFloat vx = c.x - _dragLastX, vy = c.y - _dragLastY;
        _dragLastX = c.x; _dragLastY = c.y;
        CGFloat speed = sqrtf(vx*vx + vy*vy);
        if (speed > 0.5) {
            CGFloat tilt = MAX(-0.16, MIN(0.16, vx / 160.0));  // 水平倾斜 ±9°
            _girlView.transform = CGAffineTransformMakeRotation(tilt);
        }
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _isDragging = NO;
        [self _stopLiftTimer];
        
        // v6.0.25：先恢复待机帧
        if (_liftFrames.count && _idleFrames.firstObject) {
            _girlView.image = _idleFrames.firstObject;
            _girlView.transform = CGAffineTransformIdentity;
            [self _setFrameForImage:_idleFrames.firstObject];
        }
        
        // v6.0.29：顶部松手显示掉落动画，其他位置走原来的自动吸附逻辑（每个角色独立吸附距离）
        CGSize v = [UIScreen mainScreen].bounds.size;
        CGPoint c = _girlView.center;
        CGFloat topY = _girlView.frame.size.height / 2;   // 顶部边缘的Y坐标
        
        if (_fallImage && !_falling && c.y <= topY + 50) {
            // ✅ 拖到顶部松手 → 掉落动画，坠落帧缩小到85%
            _falling = YES;
            _girlView.image = _fallImage;
            [self _setFrameForImage:_fallImage];
            // 坠落帧缩小到85%
            _girlView.transform = CGAffineTransformMakeScale(0.85, 0.85);
            
            // 目标Y：屏幕底部，X保持当前位置不变
            CGPoint endC = _girlView.center;
            endC.y = v.height - _girlView.frame.size.height / 2;
            
            // 1.2s重力缓动下坠（EaseIn，越掉越快）
            [UIView animateWithDuration:1.2 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
                _girlView.center = endC;
            } completion:^(BOOL finished) {
                // v6.1.5-14ab：掉落中若用户已拖走（_isDragging），跳过落地恢复/弹跳——拖拽已接管，
                // 原无条件恢复 idle+弹跳会打断正在进行的拖拽（角色突然变帧+transform 竞争）
                if (finished && !_isDragging) {
                    // v6.1.5-14o：活物感——落地 squash&stretch：先压扁(砸实)再弹回(颠一下)
                    if (_idleFrames.firstObject) {
                        _girlView.image = _idleFrames.firstObject;
                        [self _setFrameForImage:_idleFrames.firstObject];
                        [self _startBreathing];   // 恢复胸部呼吸动效
                    }
                    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                        _girlView.transform = CGAffineTransformMakeScale(1.18, 0.72);  // 砸实压扁
                    } completion:^(BOOL f) {
                        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.6 options:UIViewAnimationOptionCurveEaseOut animations:^{
                            _girlView.transform = CGAffineTransformIdentity;  // 弹起回正
                        } completion:nil];
                    }];
                }
                _falling = NO;   // 标志始终清，避免卡在掉落态
            }];
        } else {
            // ✅ 其他位置松手 → 走原来的贴边吸附逻辑（保留左右趴墙、底部趴墙等所有原有功能，每个角色独立配置）
            [self _snapToEdge];
        }
        // v6.1.5-14p：粒子/光晕跟随新位置
        [self _refreshAmbientPosition];
    }
}

// v6.0.12：悬空挣扎帧交替（被凭空提起、双手双腿挣扎的两帧循环）
- (void)_liftTick {
    if (!_lifting || _liftFrames.count < 2 || _isDragging == NO) return;
    _liftIdx = (_liftIdx + 1) % (int)_liftFrames.count;
    UIImage *lf = _liftFrames[_liftIdx];
    if (lf) { _girlView.image = lf; [self _setFrameForImage:lf]; }
}
- (void)_stopLiftTimer {
    [_liftTimer invalidate]; _liftTimer = nil;
    _lifting = NO;
}

// v6.1.5-14o：头顶冒 emoji 小符号（淡入→停留→淡出），挂在角色上方
- (void)_showHeadEmoji:(NSString *)emoji {
    if (!emoji.length) return;
    UIView *superview = _girlView.superview;
    if (!superview) return;
    UIView *old = [superview viewWithTag:9501];
    if (old) [old removeFromSuperview];
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    lb.tag = 9501;
    lb.text = emoji;
    lb.font = [UIFont systemFontOfSize:22];
    lb.textAlignment = NSTextAlignmentCenter;
    CGPoint c = _girlView.center;
    CGFloat top = c.y - _girlView.frame.size.height / 2 - 36;
    top = MAX(30, top);
    lb.center = CGPointMake(c.x, top);
    lb.alpha = 0;
    [superview addSubview:lb];
    [UIView animateWithDuration:0.4 animations:^{
        lb.alpha = 1.0;
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.5 delay:1.1 options:UIViewAnimationOptionCurveEaseIn animations:^{
            lb.alpha = 0;
        } completion:^(BOOL f2) {
            [lb removeFromSuperview];
        }];
    }];
}

// v6.0.8：松手吸附到最近屏幕边缘（<threshold 才算）并切换扒墙姿势（企鹅趴墙探头）
// 顶/底（水平边）用水平墙沿图 _wallImage；左/右（垂直边）用竖直墙沿图 _wallImageV。
- (void)_snapToEdge {
    [self _setAnchorY:0.5f];   // v6.0.18：趴墙→中心锚点（趴墙/悬浮不做胸部锚点）
    // v6.1.5-14ab：开头统一清吸附态动效——原提前 return 分支（顶部/未贴边）不停底部呼吸/横向挪动/姿势展示，
    // 底部趴墙后拖到中间松手，角色站中间仍残留底部起伏+挪动排期；吸附分支后面会各自重新启动
    [self _stopPoseShow];
    [self _stopBottomAmbient];
    CGSize v = [UIScreen mainScreen].bounds.size;
    CGPoint c = _girlView.center;
    CGFloat dL = c.x, dR = v.width - c.x, dT = c.y, dB = v.height - c.y;
    CGFloat minD = MIN(MIN(dL, dR), MIN(dT, dB));
    // v6.0.12：修复底部/顶部趴墙从不触发——拖拽钳制让中心距边恒为 frame 半高(站姿150→75pt)>旧阈值50，永不吸附。
    // 改为"贴边判定"：中心距边 ≤ 半高/半宽+容差即视为贴边（拖到底/顶/左右都应触发趴墙）。
    // v6.0.21：吸附判定改用【拖拽帧】半尺寸（拖到边缘钳制到 lift 帧手脚张开半宽），
    // 不再用恢复待机后的窄站姿半宽——否则 lift 半宽>站姿半宽、minD>reach 永不吸附（问题：贴左右墙不吸附）。
    CGFloat clampH = _dragHalfW > 0 ? _dragHalfW : _girlView.frame.size.width / 2;
    CGFloat clampV = _dragHalfH > 0 ? _dragHalfH : _girlView.frame.size.height / 2;
    // v6.0.27：吸附距离按角色独立配置（_snapReachH/_snapReachV，初始化时按角色分支赋值）。
    // v6.0.28：reach 取 max(配置值, 拖拽帧半尺寸)——拖拽钳制下角色中心距边最小=lift半尺寸，
    // 若配置值<lift半尺寸（如猫娘手脚张开lift半宽84>配置78）则永不吸附；MAX保证钳制贴边必吸附，配置值起提前吸附作用
    CGFloat reach = (minD == dL || minD == dR)
        ? MAX(_snapReachH, clampH) + 4.0f
        : MAX(_snapReachV, clampV) + 4.0f;   // +4pt float 容差（避免 minD==reach 边界因 float 误差不触发）
    // v6.0.27：顶部不吸附趴墙——拖到顶部仅待机（用户要求去掉所有角色顶部趴墙）
    if (minD == dT) { _girlView.transform = CGAffineTransformIdentity; [self _startBreathing]; return; }
    // v6.0.25：吸附诊断日志（每次松手输出一行，连手机 log show 定位吸附根因）
    NSLog(@"[HUDsnap] screen=%@ charScale=%.2f size=%.1f lift=%lu dragHW=(%.1f,%.1f) center=(%.1f,%.1f) dL=%.1f dR=%.1f dT=%.1f dB=%.1f clampH=%.1f clampV=%.1f reach=%.1f minD=%.1f",
          NSStringFromCGSize([UIScreen mainScreen].bounds.size), _charScale, (CGFloat)g_hud_size,
          (unsigned long)_liftFrames.count, _dragHalfW, _dragHalfH, c.x, c.y,
          dL, dR, dT, dB, clampH, clampV, reach, minD);
    if (minD > reach) { _girlView.transform = CGAffineTransformIdentity; [self _startBreathing]; return; }   // 未贴边：待机并确保漂浮在
    UIImage *wallImg = nil;
    if (minD == dL || minD == dR) wallImg = _wallImageV;   // 左/右：竖直墙沿图
    else                          wallImg = _wallImage;    // 顶/底：水平墙沿图
    // v6.0.12 兜底：某一侧趴墙图资源缺失时，退回另一侧可用墙沿图——保证贴边松手仍吸附、不致角色悬空卡在半路
    if (!wallImg) wallImg = _wallImage ?: _wallImageV;
    if (!wallImg) return;
    _girlView.image = wallImg;
    // v6.0.9：趴墙缩小显示——角色以平时一半高度贴在边缘（原用全高 size 导致趴墙角色过大、girl 底部/左右趴墙不贴合）。
    // 先设缩小尺寸，再按缩小后尺寸吸附，角色中心放屏幕边缘线、半身探出（企鹅趴墙探头效果）。
    // v6.0.21：顶/底趴墙在原50%基础上再缩25%(→37.5%)；左/右趴墙保持50%（用户只要求底部缩小）
    // v6.0.26：三款底部趴墙高度统一以萝莉为标准——wallScale 固定 1.0，不再随 charScale 放大；
    // 素材侧 rabit_wall/cat_wall 内容已缩到与 girl_wall 一致（内容高47%贴底），站姿放大(1.4/1.2/1.0)不受影响
    // v6.0.27：左右趴墙按角色放大恢复（MIN(charScale,1.2)）——用户反馈 v6.0.26 统一后猫娘左右趴墙缩小太多；
    // 底部趴墙保持统一 1.0；顶部趴墙已整体移除
    CGFloat wallScale = (wallImg == _wallImage) ? 1.0f : MIN(_charScale, 1.2f);
    CGFloat wallH = (wallImg == _wallImage)
        ? (CGFloat)g_hud_size * wallScale * 0.375
        : (CGFloat)g_hud_size * wallScale * 0.5;
    CGFloat wa = (wallImg.size.height > 0) ? (wallImg.size.width / wallImg.size.height) : 1.0;
    _girlView.bounds = CGRectMake(0, 0, wallH * wa, wallH);
    // v6.0.24 撤销：UIViewContentModeBottom 是"内容不缩放、底部对齐"，会让 wall 原图(1024×1536)按原尺寸贴底→放大数倍。
    // 改用 aspectFit 默认居中显示（v6.0.23 行为）；贴底对齐改用下面 roto 显示不在此处理（吸附/尺寸已由 bounds 决定）。
    // 吸附左缘→镜像面向左墙；右缘→正常面向右墙；上下→保持原方向
    if (minD == dL)      { c.x = _girlView.frame.size.width / 2; _girlView.transform = CGAffineTransformMakeScale(-1, 1); }
    else if (minD == dR) { c.x = v.width - _girlView.frame.size.width / 2; _girlView.transform = CGAffineTransformIdentity; }
    else if (minD == dT) { c.y = _girlView.frame.size.height / 2; _girlView.transform = CGAffineTransformIdentity; }
    else                 { c.y = v.height - _girlView.frame.size.height / 2; _girlView.transform = CGAffineTransformIdentity; }
    _girlView.center = c;
    [_girlView.layer removeAnimationForKey:@"hudFloat"];   // v6.0.14：趴墙停止上下漂浮——底部/侧趴墙不再上下起伏
    [self _stopChestBreath];   // v6.0.21：趴墙同时停胸部呼吸
    
    // v6.1.5-14w：底部趴墙 → 启动"贴底呼吸+横向挪动"；左右/其他位置 → 停止底部动效
    if (minD == dB) {
        _onBottomWall = YES;
        [self _startBottomBreath];
        [self _scheduleBottomCrawl];
    } else {
        [self _stopBottomAmbient];
    }
    
    // v6.0.26：左右边缘趴墙时，随机启动自动攀爬（10分钟内3-5次，不要太频繁）
    // v6.1.5-14x：改用可取消定时器排期（原 dispatch_after 无法取消，反复吸附会堆积多个延迟攀爬 → 爬得比气泡还频繁）
    if ((minD == dL || minD == dR) && _climbFrames.count >= 2) {
        [self _stopClimbTimer];
        // 第一次延迟30-60秒后开始攀爬
        NSTimeInterval delay = 30.0 + arc4random_uniform(30000) / 1000.0;
        [self _scheduleClimbAfterDelay:delay];
    }
    
    // v6.0.27：左右侧边趴墙时启动气泡，其他位置停止气泡
    if (minD == dL || minD == dR) {
        _onSideWall = YES;
        [self _startBubbleTimer];
        // v6.1.5-14am：侧面吸附起伏——贴墙呼吸（scale.y 1.0→1.045，纯 layer 动画不位移，不破坏贴墙）
        // 与底部呼吸共用 hudBottomBreath key，不会同时叠加两套
        [self _startBottomBreath];
        // v6.0.29：左右墙翻转角色朝向——左墙朝左，右墙朝右
        if (minD == dL) {
            _girlView.transform = CGAffineTransformMakeScale(-1, 1);
        } else {
            _girlView.transform = CGAffineTransformIdentity;
        }
    } else {
        _onSideWall = NO;
        [self _stopBubbleTimer];
        [self _stopBottomBreath];   // v6.1.5-14am：离开侧边墙停贴墙呼吸
        // 离开侧边墙恢复正常朝向
        _girlView.transform = CGAffineTransformIdentity;
    }
    // v6.1.5-14z：吸附成立后排"偶尔换坐姿/跪姿"（内部检查吸附态，非吸附不排；排期全局唯一不堆积）
    [self _schedulePoseShow];
}

// v6.0.27：启动气泡定时器
- (void)_startBubbleTimer {
    [self _stopBubbleTimer];
    // v6.0.28：隔30-60秒弹一次气泡，不要太频繁
    // v6.1.5-14s：改 15-30 秒（用户反馈看不到气泡，缩短间隔）
    NSTimeInterval interval = 15.0 + arc4random_uniform(15000) / 1000.0;
    _bubbleTimer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(NSTimer *t) {
        [self _showRandomBubble];
    }];
}

- (void)_stopBubbleTimer {
    [_bubbleTimer invalidate];
    _bubbleTimer = nil;
    [_bubbleView removeFromSuperview];
    _bubbleView = nil;
    _bubbleLabel = nil;
    [_bubbleTailLayer removeFromSuperlayer];   // v6.1.5-14ah：尖角随气泡一起销毁
    _bubbleTailLayer = nil;
}

// v6.0.27：显示随机气泡
// v6.1.5-14s：去掉"仅趴墙"限制——之前只有吸附左右墙(_onSideWall)才弹气泡，
// 且吸附后常进攀爬态(_isClimbing)被跳过 → 用户反馈"吸附左右看不到气泡消息"。
// 现在站立/趴墙任何姿势都弹，仅拖动/掉落/攀爬中不弹。
- (void)_showRandomBubble {
    if (_isHidden || _isDragging || _isClimbing || _falling) return;   // v6.1.5-14ad：隐藏态不冒气泡
    
    // v6.0.28：按时间段选问候（早/中/晚/深夜）
    NSArray *messages;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *comps = [cal components:NSHourCalendarUnit fromDate:[NSDate date]];
    NSInteger hour = comps.hour;
    NSArray *timeGreetings;
    if (hour >= 6 && hour < 11) {
        // 早上
        if ([_charPrefix isEqualToString:@"rabit"]) {
            timeGreetings = @[@"早上好呀～ 新的一天开始啦", @"早安！今天也要元气满满哦", @"起床了吗？记得吃早餐哦", @"早上好主人，昨晚睡得好吗？"];
        } else if ([_charPrefix isEqualToString:@"cat"]) {
            timeGreetings = @[@"...哼，早上好", @"这么早叫我干嘛...哦，该吃饭了？", @"早安...别烦我，我还没睡醒", @"哼，人类早上就是麻烦"];
        } else {
            timeGreetings = @[@"早安呀！太阳晒屁股啦", @"早上好！今天要玩什么？", @"起床起床！陪我玩嘛", @"早上好哥哥/姐姐！"];
        }
    } else if (hour >= 11 && hour < 14) {
        // 中午
        if ([_charPrefix isEqualToString:@"rabit"]) {
            timeGreetings = @[@"中午啦～ 记得吃午饭哦", @"午饭吃了吗？别饿肚子", @"中午好，工作歇一会吧", @"该吃饭啦，别太累着自己"];
        } else if ([_charPrefix isEqualToString:@"cat"]) {
            timeGreetings = @[@"哼，该喂饭了吧？", @"中午了，我要吃小鱼干", @"人类，你午饭吃什么？给我也来点", @"...好吧，中午了，勉强打个招呼"];
        } else {
            timeGreetings = @[@"中午好！我要吃午饭！", @"肚子饿了～ 要吃饭饭", @"中午啦，我们一起吃饭好不好？", @"哥哥/姐姐 吃了吗？"];
        }
    } else if (hour >= 14 && hour < 18) {
        // 下午
        if ([_charPrefix isEqualToString:@"rabit"]) {
            timeGreetings = @[@"下午好呀～ 喝杯茶歇一会吧", @"下午工作累不累呀？", @"下午茶时间，想吃小点心吗？", @"这个时间晒太阳好舒服"];
        } else if ([_charPrefix isEqualToString:@"cat"]) {
            timeGreetings = @[@"哼，下午了还不陪我玩", @"晒了一下午太阳，好舒服", @"人类，你下午吃零食了吗？", @"...下午好，勉强打个招呼"];
        } else {
            timeGreetings = @[@"下午好！我们一起玩吧", @"下午茶时间！吃蛋糕吗？", @"下午的阳光好舒服呀", @"哥哥/姐姐 累不累呀？"];
        }
    } else if (hour >= 18 && hour < 22) {
        // 晚上
        if ([_charPrefix isEqualToString:@"rabit"]) {
            timeGreetings = @[@"晚上好呀～ 今天辛苦了", @"下班了吗？好好休息一下", @"晚上好，我等你好久了", @"晚安之前，我会一直陪着你"];
        } else if ([_charPrefix isEqualToString:@"cat"]) {
            timeGreetings = @[@"哼，晚上了，该陪我玩了", @"晚上好...你终于回来了", @"这个点才回来？我都等饿了", @"...晚上好，就勉强理你一下"];
        } else {
            timeGreetings = @[@"晚上好！欢迎回来～", @"陪我玩嘛，白天好无聊", @"晚上吃什么好吃的？", @"我好想你呀！"];
        }
    } else {
        // 深夜/凌晨（22点到次日6点）
        if ([_charPrefix isEqualToString:@"rabit"]) {
            timeGreetings = @[@"这么晚还没睡呀？早点休息哦", @"别熬夜啦，对身体不好", @"晚安，做个好梦", @"我会在这里陪着你，快睡吧"];
        } else if ([_charPrefix isEqualToString:@"cat"]) {
            timeGreetings = @[@"...大半夜的，你还不睡？", @"哼，熬夜对身体不好哦...才不是关心你", @"快睡吧，我困了", @"晚安...别吵我"];
        } else {
            timeGreetings = @[@"好晚呀... 我困了", @"要睡觉觉啦，晚安", @"哥哥/姐姐 早点睡好不好？", @"我打哈欠了，该睡了"];
        }
    }
    
    // 50%概率弹出时间段问候，50%弹出普通台词
    BOOL showTimeGreeting = (arc4random_uniform(2) == 0);
    if (showTimeGreeting) {
        messages = timeGreetings;
    } else {
        // 按角色选普通文案（v6.0.28：每个角色58条）
        if ([_charPrefix isEqualToString:@"rabit"]) {
        messages = @[
            @"趴墙好累... 有没有人扶我一把",
            @"这个位置看风景还不错",
            @"你在看什么呢？",
            @"要吃点东西吗？我肚子饿了",
            @"工作辛苦了... 歇一会吧",
            @"今天天气真不错呢",
            @"你... 一直盯着我看干嘛",
            @"陪我说说话嘛",
            @"兔子耳朵好痒啊... 别碰！",
            @"我跳得很高哦！不信你看",
            @"今天的胡萝卜真甜呢",
            @"主人回来啦？欢迎回来~",
            @"我在这里等你好久了哦",
            @"要不要一起喝杯茶？",
            @"工作别太累了，注意身体",
            @"你看我新穿的裙子好看吗？",
            @"这个高度刚刚好，能看到你",
            @"别把我点下来嘛，我还想待一会",
            @"晚上吃什么好呢？",
            @"我刚才差点掉下去了... 好怕",
            @"主人今天心情好像不错呀",
            @"给你比个心~ 收到了吗？",
            @"我耳朵灵敏得很，你偷偷说的话我都听到了哦",
            @"要不要我给你讲个故事？",
            @"今天也辛苦啦，抱抱你",
            @"别光顾着看手机，休息一下眼睛",
            @"我在这里给你加油哦！",
            @"你打字好快呀，好厉害",
            @"渴不渴？记得喝水哦",
            @"坐久了站起来活动活动吧",
            @"我帮你盯着屏幕，有消息我叫你",
            @"这个角度我能看到你在笑哦",
            @"偷偷告诉你，我最喜欢你了",
            @"累了就看看我，放松一下",
            @"我会一直在这里陪着你的",
            @"今天也要元气满满哦！",
            @"主人最棒了！",
            @"有我在，什么都不怕",
            @"要不要捏捏我的脸？",
            @"我软乎乎的，好摸得很",
            @"别皱眉头啦，笑一个嘛",
            @"你笑起来真好看，多笑笑",
            @"我在这里给你暖手",
            @"天冷了，多穿点衣服",
            @"明天也要好好努力呀",
            @"我会乖乖的，不捣乱",
            @"需要我帮忙就说哦",
            @"我随时都在",
            @"爱你哦~",
            @"想你了",
            @"你在我就在",
            @"永远陪着你",
            @"么么哒",
            @"啾咪",
            @"抱抱",
            @"贴贴"
        ];
    } else if ([_charPrefix isEqualToString:@"cat"]) {
        messages = @[
            @"哼... 才不是故意趴在这的！",
            @"别误会！我只是歇一会！",
            @"你... 你要看多久啊！",
            @"摸头的话... 也不是不行啦",
            @"快... 快夸我可爱！",
            @"才... 才不是想待在你旁边！",
            @"给我点小鱼干！不然我不理你了",
            @"哼... 笨蛋主人",
            @"爪子好脏，才不要碰你",
            @"我只是随便趴趴，别多想",
            @"猫尾巴好舒服... 别摸！",
            @"本喵今天心情好，允许你看我",
            @"你在干嘛？还不快过来撸猫",
            @"哼，人类就是麻烦",
            @"我才不会想你呢，别自作多情",
            @"...好吧，有一点点想",
            @"给我买罐头，我就原谅你",
            @"别摸我头！...再摸一下也可以",
            @"我生气了！哄不好的那种！...给点小鱼干就好",
            @"你在看什么？没见过美女猫吗？",
            @"本喵的姿态优美吧",
            @"这个位置晒太阳真舒服",
            @"别把我挪走！我就要待这",
            @"主人回来啦？...哦",
            @"我才没有等你回来，只是刚好在这",
            @"你工作的时候我就在旁边看着",
            @"不准摸别的猫！你只能有我一个",
            @"哼，你敢摸别的猫试试",
            @"我可是很高冷的，别太靠近",
            @"...再靠近一点点也可以",
            @"给我挠挠下巴，舒服",
            @"呼噜呼噜... 别停",
            @"我踩奶了哦，说明我信任你",
            @"别碰我尾巴！这是底线",
            @"爪子磨好了，你的沙发小心点",
            @"我跳得很准，不会掉下去",
            @"这个高度刚刚好，能盯着你",
            @"你偷偷吃零食我都看到了",
            @"给我也尝一口！小气鬼",
            @"我才不饿，就是看着你吃",
            @"...好吧，我也想吃",
            @"我睡觉的时候不准偷看",
            @"我打哈欠可爱吧？别拍！",
            @"耳朵动了，说明我注意到你了",
            @"尾巴甩你，是我喜欢你的意思",
            @"哼，勉强夸你一句：你还不错",
            @"别离开我太久，我会生气的",
            @"...我会担心的",
            @"好了，我允许你抱一下",
            @"就一下哦！多了不行",
            @"我喜欢你... 才怪！",
            @"...一点点啦",
            @"mua",
            @"喵",
            @"呼噜",
            @"蹭蹭",
            @"贴贴",
            @"哼唧"
        ];
    } else {
        messages = @[
            @"趴高高！看得到好远！",
            @"这里好凉好舒服~",
            @"要一起玩吗？",
            @"肚子饿了... 想吃蛋糕",
            @"哥哥/姐姐 你在干嘛呀？",
            @"我好无聊... 陪我玩嘛",
            @"刚才那个人是不是看我了？",
            @"我今天乖不乖呀？",
            @"我爬上来啦！厉害不？",
            @"这个高度能看到整个房间！",
            @"我要吃草莓蛋糕！",
            @"哥哥/姐姐 在打字吗？",
            @"我给你加油哦！",
            @"你看我穿小裙子好看吗？",
            @"头发是不是乱了？帮我看看",
            @"要不要玩躲猫猫？",
            @"数到十就来找我哦！",
            @"我藏得好不好？",
            @"找到我啦！哇好厉害",
            @"再玩一次嘛！",
            @"我想听故事",
            @"讲个小兔子的故事好不好？",
            @"我睡觉会抱玩偶哦",
            @"今天我自己穿的鞋子！",
            @"厉害吧？我长大了！",
            @"哥哥/姐姐 不要加班啦",
            @"早点陪我玩嘛",
            @"我在这里等你哦",
            @"你回来啦！抱抱！",
            @"欢迎回来~",
            @"我给你留了小零食",
            @"我们一起吃好不好？",
            @"这个糖给你吃，甜不甜？",
            @"我刚才画了一幅画，给你看",
            @"画的是我们俩！",
            @"好看吗？我涂的颜色",
            @"我今天在幼儿园得了小红花！",
            @"老师夸我乖哦",
            @"我给你戴小红花！",
            @"你也是最棒的哥哥/姐姐",
            @"我们拉钩钩！",
            @"拉钩上吊，一百年不许变",
            @"我要跟你永远在一起",
            @"你不要离开我好不好？",
            @"我会想你的",
            @"亲亲",
            @"抱抱",
            @"举高高！",
            @"我喜欢你！",
            @"最喜欢你了！",
            @"mua~",
            @"啾~",
            @"哇！",
            @"嘿嘿",
            @"嘻嘻",
            @"好呀好呀",
            @"太棒了！",
            @"耶！"
        ];
        }
    }
    
    NSString *msg = messages[arc4random_uniform((uint32_t)messages.count)];
    
    // v6.0.28：读取气泡样式设置（0=经典圆角 1=椭圆 2=方形硬边 3=爆炸吐槽）
    int bubbleStyle = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"trollmcp2.bubble_style"];
    
    // 换样式之后旧气泡扔掉，下次重新创建
    if (_bubbleView) {
        [_bubbleView removeFromSuperview];
        _bubbleView = nil;
        _bubbleLabel = nil;
        [_bubbleTailLayer removeFromSuperlayer];   // v6.1.5-14ah：尖角随旧气泡一起销毁
        _bubbleTailLayer = nil;
    }
    // 创建卡通漫画气泡（带小尾巴）
    if (!_bubbleLabel) {
        // 用UIView画带尾巴的气泡
        UIView *bubbleView = [[UIView alloc] init];
        bubbleView.alpha = 0;
        
        // 根据样式设置外观
        if (bubbleStyle == 3) {
            // 爆炸吐槽：黄色背景，黑色边框
            bubbleView.backgroundColor = [UIColor systemYellowColor];
            bubbleView.layer.cornerRadius = 8;
            bubbleView.layer.masksToBounds = YES;
            bubbleView.layer.borderWidth = 2;
            bubbleView.layer.borderColor = [UIColor blackColor].CGColor;
        } else if (bubbleStyle == 2) {
            // 方形硬边：白色背景，黑色边框，直角
            bubbleView.backgroundColor = [UIColor whiteColor];
            bubbleView.layer.cornerRadius = 0;
            bubbleView.layer.masksToBounds = YES;
            bubbleView.layer.borderWidth = 2;
            bubbleView.layer.borderColor = [UIColor blackColor].CGColor;
        } else if (bubbleStyle == 1) {
            // 椭圆气泡：粉色背景，无边框，大圆角
            bubbleView.backgroundColor = [UIColor systemPinkColor];
            bubbleView.layer.cornerRadius = 20;
            bubbleView.layer.masksToBounds = YES;
        } else {
            // 经典圆角（默认）：白色背景，粉色边框
            bubbleView.backgroundColor = [UIColor whiteColor];
            bubbleView.layer.cornerRadius = 14;
            bubbleView.layer.masksToBounds = YES;
            bubbleView.layer.borderWidth = 2;
            bubbleView.layer.borderColor = [UIColor systemPinkColor].CGColor;
        }
        
        UILabel *label = [[UILabel alloc] init];
        if (bubbleStyle == 1) {
            label.textColor = [UIColor whiteColor];
        } else if (bubbleStyle == 3) {
            label.textColor = [UIColor blackColor];
        } else {
            label.textColor = [UIColor darkGrayColor];
        }
        label.font = [UIFont systemFontOfSize:14];
        label.numberOfLines = 0;
        [bubbleView addSubview:label];
        _bubbleLabel = label;
        _bubbleView = bubbleView;
    }
    
    _bubbleLabel.text = msg;
    
    // v6.0.28：限制气泡最大宽度为屏幕宽度的80%，文字自动换行
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat maxBubbleW = screenSize.width * 0.8;
    CGFloat labelMaxW = maxBubbleW - 24;
    _bubbleLabel.preferredMaxLayoutWidth = labelMaxW;
    [_bubbleLabel sizeToFit];
    
    // 调整气泡大小，加内边距
    CGRect labelF = _bubbleLabel.frame;
    // 确保气泡宽度不超过最大值
    CGFloat bubbleW = MIN(labelF.size.width + 24, maxBubbleW);
    CGFloat bubbleH = labelF.size.height + 16;
    _bubbleView.frame = CGRectMake(0, 0, bubbleW, bubbleH);
    _bubbleLabel.frame = CGRectMake(12, 8, bubbleW - 24, labelF.size.height);
    
    // v6.0.28：气泡位置改成在角色头顶上方，小尾巴朝下指向角色
    CGFloat tailW = 12;
    CGFloat tailH = 10;
    
    // 气泡位置：角色头顶上方
    CGPoint c = _girlView.center;
    CGFloat bubbleX = c.x;
    // 气泡在角色头顶上方，距离角色顶部15pt
    CGFloat bubbleY = c.y - _girlView.frame.size.height / 2 - bubbleH / 2 - 15;
    
    // v6.0.28：边界检查，不让气泡超出屏幕左右边界
    CGFloat bubbleLeft = bubbleX - bubbleW / 2;
    CGFloat bubbleRight = bubbleX + bubbleW / 2;
    if (bubbleLeft < 10) {
        bubbleX = 10 + bubbleW / 2;
    }
    if (bubbleRight > screenSize.width - 10) {
        bubbleX = screenSize.width - 10 - bubbleW / 2;
    }
    // 顶部边界检查，不让气泡超出屏幕顶部
    if (bubbleY - bubbleH / 2 < 10) {
        bubbleY = 10 + bubbleH / 2;
    }
    _bubbleView.center = CGPointMake(bubbleX, bubbleY);
    
    // v6.1.5-14ah：尖角（小尾巴）画到父视图 self.view 上——气泡本体 masksToBounds=YES 会把画在
    // 边界外的三角顶点整个裁掉（用户反馈"气泡没有指向尖角"）。父视图不裁剪，尖角完整露出。
    if (!_bubbleTailLayer) {
        _bubbleTailLayer = [CAShapeLayer layer];
        [self.view.layer addSublayer:_bubbleTailLayer];
    }
    CGRect bf = _bubbleView.frame;   // 气泡直接 add 到 self.view，frame 即父视图坐标
    CGFloat tailX = bf.origin.x + bf.size.width / 2;
    // v6.1.5-14ao：顶边嵌入气泡内 2pt——气泡圆角/边框盖住三角形顶边接缝，
    // 避免"尖角处有条线"（三角形平顶边 vs 气泡圆角底边的缝隙）
    CGFloat tailY = bf.origin.y + bf.size.height - 2;
    UIBezierPath *tailPath = [UIBezierPath bezierPath];
    [tailPath moveToPoint:CGPointMake(tailX - tailW/2, tailY)];
    [tailPath addLineToPoint:CGPointMake(tailX, tailY + tailH)];
    [tailPath addLineToPoint:CGPointMake(tailX + tailW/2, tailY)];
    [tailPath closePath];
    _bubbleTailLayer.path = tailPath.CGPath;
    // v6.0.28：尾巴颜色跟着气泡样式走
    // v6.1.5-14ao：全部去描边（strokeColor=clear, lineWidth=0）——原黑/粉描边+2pt 线宽
    // 在尖角轮廓上画一圈线，用户反馈"尖角那里拦着线"；纯填充与气泡同色融合
    if (bubbleStyle == 3) {
        _bubbleTailLayer.fillColor = [UIColor systemYellowColor].CGColor;
    } else if (bubbleStyle == 2) {
        _bubbleTailLayer.fillColor = [UIColor whiteColor].CGColor;
    } else if (bubbleStyle == 1) {
        _bubbleTailLayer.fillColor = [UIColor systemPinkColor].CGColor;
    } else {
        _bubbleTailLayer.fillColor = [UIColor whiteColor].CGColor;
    }
    _bubbleTailLayer.strokeColor = [UIColor clearColor].CGColor;
    _bubbleTailLayer.lineWidth = 0;
    
    if (!_bubbleView.superview) {
        [self.view addSubview:_bubbleView];
    }
    
    // v6.1.5-14ah：尖角与气泡同步淡入淡出（CABasicAnimation 走 opacity，CAShapeLayer 不跟 UIView 动画）
    _bubbleTailLayer.opacity = 0;
    CABasicAnimation *tf = [CABasicAnimation animationWithKeyPath:@"opacity"];
    tf.fromValue = @(0.0); tf.toValue = @(1.0); tf.duration = 0.3; tf.beginTime = 0;
    tf.removedOnCompletion = NO; tf.fillMode = kCAFillModeForwards;
    [_bubbleTailLayer addAnimation:tf forKey:@"tailFadeIn"];
    CABasicAnimation *to = [CABasicAnimation animationWithKeyPath:@"opacity"];
    to.fromValue = @(1.0); to.toValue = @(0.0); to.duration = 0.3;
    to.beginTime = CACurrentMediaTime() + 2.0;
    to.removedOnCompletion = NO; to.fillMode = kCAFillModeForwards;
    [_bubbleTailLayer addAnimation:to forKey:@"tailFadeOut"];
    
    // 淡入淡出
    [UIView animateWithDuration:0.3 animations:^{
        _bubbleView.alpha = 1.0;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:2.0 options:0 animations:^{
            _bubbleView.alpha = 0;
        } completion:^(BOOL finished) {
            [_bubbleView removeFromSuperview];
            _bubbleView = nil;
            _bubbleLabel = nil;
            [_bubbleTailLayer removeFromSuperlayer];  // v6.1.5-14ah：尖角随气泡一起销毁
            _bubbleTailLayer = nil;
        }];
    }];
}

// v6.0.26：开始自动攀爬
- (void)_startClimbing {
    if (_isClimbing || _isDragging || _falling) return;
    if (!_climbFrames.count) return;
    // v6.1.5-14t：必须真正处于侧边趴墙态才爬——原只判断"离左右墙哪个近"(minD==dL/dR)，
    // 角色站在屏幕边缘附近(未吸附)也会被判"在左墙"→ 站着爬！加 _onSideWall 检查
    if (!_onSideWall) return;
    
    // v6.0.29：必须在左右侧边墙才启动攀爬，底部/顶部不爬
    CGSize v = [UIScreen mainScreen].bounds.size;
    CGPoint c = _girlView.center;
    CGFloat dL = c.x, dR = v.width - c.x, dT = c.y, dB = v.height - c.y;
    CGFloat minD = MIN(MIN(dL, dR), MIN(dT, dB));
    if (minD != dL && minD != dR) return;   // 不是左右墙，不爬
    
    _isClimbing = YES;
    _climbIdx = 0;
    [self _stopBottomBreath];   // v6.1.5-14am：攀爬中停贴墙呼吸，避免呼吸起伏与爬动帧叠加
    
    // 记录当前在哪一侧边缘，爬的时候保持朝向一致
    BOOL onLeftEdge = (minD == dL);
    
    // 用第一帧开始攀爬，保持朝向——左墙朝左，右墙朝右
    UIImage *cf = _climbFrames[0];
    _girlView.image = cf;
    if (onLeftEdge) {
        _girlView.transform = CGAffineTransformMakeScale(-1, 1);
    } else {
        _girlView.transform = CGAffineTransformIdentity;
    }
    // v6.1.5-14u：攀爬帧按趴墙同款尺寸（50%高度×charScale）——原 _setFrameForImage 用站姿全尺寸，
    // 猫娘手脚张开帧比趴墙大一倍、贴边时手脚被屏幕边缘裁掉
    [self _setClimbFrameSize:cf];
    
    // 随机选择向上或向下攀爬
    BOOL climbUp = (arc4random_uniform(2) == 0);   // 50%概率向上，50%向下
    CGFloat moveStep = climbUp ? -40 : 40;   // 每步40pt
    
    // 每隔0.4秒切换一次攀爬帧，同时移动
    _climbTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
        _climbIdx++;
        if (_climbIdx >= 6) {   // 爬6步就停，恢复趴墙
            [self _stopClimbing];
            return;
        }
        
        // 切换攀爬帧
        UIImage *nextFrame = _climbFrames[_climbIdx % 2];
        _girlView.image = nextFrame;
        [self _setClimbFrameSize:nextFrame];
        
        // 边界检查：如果已经到底部/顶部，就不继续爬了
        CGFloat halfH = _girlView.frame.size.height / 2;
        CGPoint c = _girlView.center;
        CGFloat newY = c.y + moveStep;
        // 已经在底部还想往下爬，或已经在顶部还想往上爬，就停
        if ((moveStep > 0 && c.y >= v.height - halfH - 5) ||
            (moveStep < 0 && c.y <= halfH + 5)) {
            [self _stopClimbing];
            return;
        }
        c.y = MAX(halfH, MIN(newY, v.height - halfH));
        // v6.1.5-14u：爬动时保持贴边（x 不随帧宽变化漂移，避免手脚被边缘裁切/离墙）
        CGFloat halfW = _girlView.frame.size.width / 2;
        c.x = onLeftEdge ? halfW : (v.width - halfW);
        _girlView.center = c;
    }];
}

// v6.1.5-14u：攀爬帧尺寸——猫娘缩到趴墙 50% 高度（手脚不被屏幕边缘裁）；
// v6.1.5-14am：girl/rabit 攀爬用站姿全尺寸（原"所有角色统一缩小"误伤其他角色，用户反馈恢复）
- (void)_setClimbFrameSize:(UIImage *)img {
    if (!img || !_girlView) return;
    CGSize v = [UIScreen mainScreen].bounds.size;
    CGFloat climbH;
    if (_isCatChar) {
        climbH = (CGFloat)g_hud_size * MIN(_charScale, 1.2f) * 0.5;   // 猫娘：趴墙同款 50%
    } else {
        climbH = (CGFloat)g_hud_size * _charScale;                    // girl/rabit：站姿全尺寸
    }
    CGFloat wa = (img.size.height > 0) ? (img.size.width / img.size.height) : 1.0;
    _girlView.bounds = CGRectMake(0, 0, climbH * wa, climbH);
    CGPoint c = _girlView.center;
    // 重新贴边：左墙中心=半宽，右墙中心=屏宽-半宽（保持朝向由 transform 负责）
    CGFloat halfW = _girlView.frame.size.width / 2;
    if (c.x <= v.width / 2) c.x = halfW;
    else c.x = v.width - halfW;
    _girlView.center = c;
}

// v6.0.26：停止攀爬，恢复趴墙
- (void)_stopClimbing {
    [_climbTimer invalidate];
    _climbTimer = nil;
    _isClimbing = NO;
    
    // 恢复原来的趴墙图
    CGSize v = [UIScreen mainScreen].bounds.size;
    CGPoint c = _girlView.center;
    CGFloat dL = c.x, dR = v.width - c.x;
    UIImage *wallImg = _wallImageV;
    if (wallImg) {
        _girlView.image = wallImg;
        // 重新设置趴墙尺寸
        CGFloat wallScale = MIN(_charScale, 1.2f);
        CGFloat wallH = (CGFloat)g_hud_size * wallScale * 0.5;
        CGFloat wa = (wallImg.size.height > 0) ? (wallImg.size.width / wallImg.size.height) : 1.0;
        _girlView.bounds = CGRectMake(0, 0, wallH * wa, wallH);
        // 重新吸附到边缘，左墙朝左（翻转），右墙朝右（正常）
        if (dL < dR) {
            c.x = _girlView.frame.size.width / 2;
            _girlView.transform = CGAffineTransformMakeScale(-1, 1);
        } else {
            c.x = v.width - _girlView.frame.size.width / 2;
            _girlView.transform = CGAffineTransformIdentity;
        }
        _girlView.center = c;
    }
    
    // 爬完之后，过2-3分钟自动再爬一次，10分钟内总共3-5次，不要太频繁
    // v6.1.5-14x：改可取消定时器（原 dispatch_after 反复触发会堆积）
    NSTimeInterval nextDelay = 120.0 + arc4random_uniform(60000) / 1000.0;
    [self _scheduleClimbAfterDelay:nextDelay];
}

// v6.1.5-14x：攀爬延迟排期——可取消定时器，全局唯一（新排期会 invalidate 旧的，杜绝堆积）
- (void)_scheduleClimbAfterDelay:(NSTimeInterval)delay {
    [_climbSchedTimer invalidate];
    _climbSchedTimer = nil;
    _climbSchedTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                        target:self
                                                      selector:@selector(_tryStartClimbing)
                                                      userInfo:nil repeats:NO];
}
- (void)_tryStartClimbing {
    _climbSchedTimer = nil;
    // 必须仍在左右趴墙态且未被拖拽/掉落才爬；v6.1.5-14z：坐姿/跪姿展示中不爬
    // v6.1.5-14aa：展示中不丢弃排期——推迟 2-3 分钟再试（原直接 return 导致之后永不再攀爬）
    if (_poseShowing) { [self _scheduleClimbAfterDelay:120.0 + arc4random_uniform(60000) / 1000.0]; return; }
    // v6.1.5-14ad：隐藏态（缩小成点）不攀爬，推迟再试
    if (_isHidden) { [self _scheduleClimbAfterDelay:120.0 + arc4random_uniform(60000) / 1000.0]; return; }
    if (!_onSideWall || _isDragging || _falling || _isClimbing) return;
    [self _startClimbing];
}

- (void)_stopClimbTimer {
    [_climbTimer invalidate];
    _climbTimer = nil;
    [_climbSchedTimer invalidate];   // v6.1.5-14x：拖拽时连延迟排期一起清，避免拖走后还触发攀爬
    _climbSchedTimer = nil;
    _isClimbing = NO;
}

// v6.1.5-14w：底部趴墙动效——贴底呼吸（肚皮起伏，layer scale.y 关键帧，不影响翻转 transform）
- (void)_startBottomBreath {
    [_girlView.layer removeAnimationForKey:@"hudBottomBreath"];
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
    a.values = @[@1.0f, @1.045f, @1.0f];
    a.keyTimes = @[@0.0f, @0.5f, @1.0f];
    a.duration = 1.2;
    a.repeatCount = INFINITY;
    a.calculationMode = kCAAnimationCubic;
    [_girlView.layer addAnimation:a forKey:@"hudBottomBreath"];
}
- (void)_stopBottomBreath {
    [_girlView.layer removeAnimationForKey:@"hudBottomBreath"];
}

// v6.1.5-14w：底部趴墙动效——横向小碎步挪动（30-60s 一次，随机方向缓动 60-120pt）
- (void)_scheduleBottomCrawl {
    [_bottomCrawlTimer invalidate];
    _bottomCrawlTimer = nil;
    if (!_onBottomWall) return;
    NSTimeInterval delay = 30.0 + arc4random_uniform(30000) / 1000.0;
    _bottomCrawlTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                         target:self
                                                       selector:@selector(_doBottomCrawl)
                                                       userInfo:nil repeats:NO];
}
- (void)_doBottomCrawl {
    _bottomCrawlTimer = nil;
    if (!_onBottomWall || _isDragging || _falling || _isClimbing) return;
    if (_poseShowing) { [self _scheduleBottomCrawl]; return; }   // v6.1.5-14z：坐姿/跪姿展示中跳过本次挪动
    if (_isHidden) { [self _scheduleBottomCrawl]; return; }       // v6.1.5-14ad：隐藏态不挪动
    CGSize v = [UIScreen mainScreen].bounds.size;
    CGFloat halfW = _girlView.frame.size.width / 2;
    CGFloat curX = _girlView.center.x;
    int dir = (arc4random_uniform(2) == 0) ? -1 : 1;
    CGFloat step = 60.0 + arc4random_uniform(61);   // 60-120pt
    CGFloat nx = curX + dir * step;
    nx = MAX(halfW, MIN(nx, v.width - halfW));
    if (fabs(nx - curX) < 8) { [self _scheduleBottomCrawl]; return; }   // 已到头：换方向下次再说
    [UIView animateWithDuration:1.2 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_girlView.center = CGPointMake(nx, self->_girlView.center.y);
    } completion:^(BOOL f) {
        [self _scheduleBottomCrawl];
    }];
}

// v6.1.5-14w：停止底部动效（呼吸+挪动），离开底部趴墙/拖拽/恢复站立时调用
- (void)_stopBottomAmbient {
    _onBottomWall = NO;
    [_bottomCrawlTimer invalidate];
    _bottomCrawlTimer = nil;
    [self _stopBottomBreath];
}

// v6.1.5-14z：侧面吸附（左右墙）偶尔"活过来"——坐姿/跪姿展示2.5-3s再趴回。
// 频率1小时3-5次（720-1200s随机），左右两侧都自然触发（在哪侧吸附就在哪侧原地展示）；
// 全部用可取消定时器，全局唯一排期，打断即作废、趴回时由 _snapToEdge 统一重建攀爬排期 → 不堆积。
// 仅侧面（_onSideWall）触发；底部趴墙已有呼吸+横向挪动，不叠加
- (void)_schedulePoseShow {
    [_poseShowTimer invalidate];
    _poseShowTimer = nil;
    if (_poseShowing || !_onSideWall) return;
    NSTimeInterval delay = 720.0 + arc4random_uniform(48000) / 100.0;   // 720-1199s ≈ 1小时3-5次
    _poseShowTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                      target:self
                                                    selector:@selector(_poseShowFire)
                                                    userInfo:nil repeats:NO];
}
- (void)_poseShowFire {
    _poseShowTimer = nil;
    if (_poseShowing || _isDragging || _falling || _isClimbing || _isHidden) { [self _schedulePoseShow]; return; }
    if (!_onSideWall) { [self _schedulePoseShow]; return; }
    _poseShowing = YES;
    // 展示期间停攀爬排期（趴回时 _snapToEdge 会重建，避免展示中爬动冲突）
    [_climbSchedTimer invalidate]; _climbSchedTimer = nil;
    CGPoint c = _girlView.center;
    // 随机坐姿/跪姿帧（squat 池：squat/kneel/sit/side_sit/kneel_up/chin_sit 等，多帧随机更有变化）
    UIImage *poseImg = nil;
    if (_squatFrames.count) {
        poseImg = _squatFrames[arc4random_uniform((uint32_t)_squatFrames.count)];
    } else if (_idleFrames.firstObject) {
        poseImg = _idleFrames.firstObject;   // 兜底：该角色无坐姿/跪姿帧时才用站立
    }
    if (!poseImg) { _poseShowing = NO; [self _schedulePoseShow]; return; }
    _girlView.image = poseImg;
    _girlView.transform = CGAffineTransformIdentity;   // 站直/坐正（恢复朝向）
    [self _setFrameForImage:poseImg];
    _girlView.center = c;   // 保持吸附位置原地换姿势
    // 展示 2.5-3s 后趴回
    _poseHoldTimer = [NSTimer scheduledTimerWithTimeInterval:2.5 + arc4random_uniform(60) / 100.0
                                                      target:self
                                                    selector:@selector(_poseReattach)
                                                    userInfo:nil repeats:NO];
}
- (void)_poseReattach {
    _poseHoldTimer = nil;
    _poseShowing = NO;
    [self _snapToEdge];          // 按当前中心重新吸附（自动恢复趴墙图/底部呼吸/攀爬/底部挪动排期，末尾会重排下一次展示）
}
// v6.1.5-14z：打断展示（拖拽/点击/长按/锁屏/隐藏），排期与保持计时一并作废
- (void)_stopPoseShow {
    [_poseShowTimer invalidate]; _poseShowTimer = nil;
    [_poseHoldTimer invalidate]; _poseHoldTimer = nil;
    _poseShowing = NO;
}

// 点击切表情：开心→思考→待机
// v6.0.8：切帧时按新帧内容比例重设 frame（高度固定 size、宽按比例、保持中心）——
// 兔女郎各动作帧内容比例差异巨大(idle 0.25 vs happy 0.52)，固定 init 的窄框会让 aspectFit 缩放导致"一下大一下小"。
- (void)_setFrameForImage:(UIImage *)img {
    if (!img || !_girlView) return;
    CGPoint center = _girlView.center;
    CGFloat size = (CGFloat)g_hud_size * _charScale;   // v6.0.12：乘角色放大系数（兔娘1.4/猫娘1.2）
    // v6.0.17：蹲坐/跪姿帧整体 ×0.55——按用户最终定案（蹲坐原图比站姿大太多，缩到用户认可的协调比例）
    // v6.0.19：蹲坐/跪姿帧整体 ×0.7——用户从0.55回调（0.55太小说不清表情，0.7居中协调）
    if (_squatFrames && [_squatFrames containsObject:img]) size = size * 0.7f;
    if (_liftFrames && [_liftFrames containsObject:img]) size = size * 0.8f;   // v6.0.14：悬空帧手脚张开占画面大，缩小显示使头部/手臂面积≈站姿
    CGFloat aspect = (img.size.height > 0) ? (img.size.width / img.size.height) : 1.0;
    CGFloat w = size * aspect;
    CGFloat h = size;
    // v6.0.10：横向帧（趴着/横躺，裁剪后 aspect>1，如 rabit_prone）限制宽度≤size、高度按比例——
    // 否则横向动作宽=size*aspect 会撑得过大（rabit_prone aspect1.45 → 217pt 宽）。
    if (w > size) { w = size; h = w / aspect; }
    _girlView.bounds = CGRectMake(0, 0, w, h);
    _girlView.center = center;   // 保持中心，切换时不跳
    // v6.0.24：仅站立姿势保留胸部动效——蹲坐/悬空/趴墙帧时移除（用户只要站立有）；站立帧按新 bounds 重建
    if (_chestLayer || _chestLayerR) {
        BOOL nonStand = (img == _wallImage || img == _wallImageV)
                     || (_liftFrames && [_liftFrames containsObject:img])
                     || (_squatFrames && [_squatFrames containsObject:img]);
        if (nonStand) [self _stopChestBreath];
        else          [self _startChestBreath];
    }
}
// v6.1.5-14o：活物感——双击：向上蹦跳+happy帧+挤压拉伸（squash&stretch），不动菜单
- (void)_doubleTap:(UITapGestureRecognizer *)g {
    if (_isDragging || _falling) return;
    [self _stopPoseShow];   // v6.1.5-14z：双击打断坐姿/跪姿展示
    if (_isHidden) return;  // 隐藏态交给单击恢复
    if (_girlView.image == _wallImage || _girlView.image == _wallImageV) return;  // 趴墙时交给单击恢复站立
    UIImage *hp = _happyFrames.firstObject;
    if (!hp && _idleFrames.firstObject) hp = _idleFrames.firstObject;
    if (hp) _girlView.image = hp;
    CGPoint c = _girlView.center;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        // 蹦起：先压扁蓄力再弹起
        _girlView.transform = CGAffineTransformMakeScale(1.15, 0.85);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            _girlView.center = CGPointMake(c.x, c.y - 26);  // 蹦起 26pt
            _girlView.transform = CGAffineTransformMakeScale(0.92, 1.08);  // 上升拉长
        } completion:^(BOOL f2) {
            [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
                _girlView.center = c;
                _girlView.transform = CGAffineTransformIdentity;  // 落回原位
            } completion:^(BOOL f3) {
                [self _resetToIdleIfNeeded];
            }];
        }];
    }];
}
// v6.1.5-14o：活物感——长按：捏扁（压扁变宽），松手弹回（spring）
- (void)_longPress:(UILongPressGestureRecognizer *)g {
    if (_isDragging || _falling || _isHidden) return;
    [self _stopPoseShow];   // v6.1.5-14z：长按打断坐姿/跪姿展示
    if (g.state == UIGestureRecognizerStateBegan) {
        [UIView animateWithDuration:0.18 animations:^{
            _girlView.transform = CGAffineTransformMakeScale(1.25, 0.65);  // 捏扁
        }];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.45 initialSpringVelocity:0.8 options:UIViewAnimationOptionCurveEaseOut animations:^{
            _girlView.transform = CGAffineTransformIdentity;  // 弹回
        } completion:^(BOOL f) {
            [self _resetToIdleIfNeeded];
        }];
    }
}
// v6.1.5-14o：被摸/长按/蹦跳结束后若切了 happy 帧且非特殊状态，回到待机帧
- (void)_resetToIdleIfNeeded {
    [self _stopBottomAmbient];   // v6.1.5-14w：任何回待机路径都停底部动效
    // v6.1.5-14aa：加 _onBottomWall——原只判 _onSideWall，底部趴墙漏判，
    // 长按捏扁弹回时把角色从趴底错误拉回站姿待机
    if (_isDragging || _falling || _isClimbing || _onSideWall || _onBottomWall) return;
    if (_idleFrames.firstObject && _girlView.image != _idleFrames.firstObject) {
        _girlView.image = _idleFrames.firstObject;
        [self _setFrameForImage:_idleFrames.firstObject];
        [self _startBreathing];
    }
}

- (void)_tap:(UITapGestureRecognizer *)g {
    if (_isDragging || _falling) return;   // v6.1.5-14ab：掉落中不可点击
    [self _stopPoseShow];   // v6.1.5-14z：单击打断坐姿/跪姿展示
    // v6.0.8：从扒墙状态点击 → 直接恢复站立待机（不切表情）
    if ((_girlView.image == _wallImage || _girlView.image == _wallImageV) && _idleFrames.firstObject) {
        [self _stopBottomAmbient];   // v6.1.5-14w：恢复站立停底部动效
        _girlView.image = _idleFrames.firstObject;
        _girlView.transform = CGAffineTransformIdentity;
        [self _setFrameForImage:_idleFrames.firstObject];
        [self _startBreathing];   // v6.0.14：从趴墙恢复待机，重启漂浮
        return;
    }
    // 如果现在是隐藏缩小状态，点一下先恢复
    if (_isHidden) {
        _isHidden = NO;
        [UIView animateWithDuration:0.3 animations:^{
            _girlView.transform = CGAffineTransformIdentity;
            self.view.alpha = 1.0;
        }];
        return;
    }
    // v6.0.30: 单击弹出自适应扇形快捷菜单，不切表情了
    // 先检查菜单是不是已经弹出来了，弹出来就关掉
    BOOL menuVisible = NO;
    for (UIView *v in self.view.subviews) {
        if (v.tag >= 9000 && v.tag < 9100) { menuVisible = YES; break; }
    }
    if (menuVisible) {
        [self _closeFanMenu];
    } else {
        [self _showFanMenu];
    }
}

// v6.0.30: 扇形快捷菜单
// v6.1.5: 快捷菜单美化——扇形按钮加阴影+SF Symbol图标+白字描边；纵向列表改卡片式
- (NSString *)_symbolForName:(NSString *)name url:(NSString *)url {
    NSString *u = (url ? url : @"").lowercaseString;
    if ([u containsString:@"weixin"] || [name containsString:@"微信"]) return @"bubble.left.fill";
    if ([u containsString:@"snssdk"] || [name containsString:@"抖音"]) return @"play.tv.fill";
    if ([u containsString:@"camera"] || [name containsString:@"相机"]) return @"camera.fill";
    if ([u containsString:@"app-prefs"] || [name containsString:@"设置"]) return @"gearshape.fill";
    if ([u containsString:@"trollagent://chat"]) return @"sparkles";
    if ([u containsString:@"trollagent://hide"]) return @"eye.slash.fill";
    if ([name containsString:@"微博"]) return @"at";
    if ([name containsString:@"淘宝"]) return @"cart.fill";
    if ([name containsString:@"京东"]) return @"bag.fill";
    if ([name containsString:@"美团"]) return @"fork.knife";
    if ([name containsString:@"地图"]) return @"map.fill";
    if ([name containsString:@"音乐"]) return @"music.note";
    if ([name containsString:@"相册"] || [name containsString:@"照片"]) return @"photo.fill";
    if ([name containsString:@"邮件"]) return @"envelope.fill";
    if ([name containsString:@"电话"]) return @"phone.fill";
    if ([name containsString:@"浏览器"]) return @"safari.fill";
    if ([name containsString:@"QQ"]) return @"message.fill";
    return @"square.grid.2x2.fill";
}

- (void)_showFanMenu {
    // v6.1.5-9：菜单精致化——毛玻璃背景面板 + 名称胶囊 + 逐个弹性入场（统一 tag 9000+ 便于清理）
    for (UIView *v in self.view.subviews) {
        if (v.tag >= 9000) [v removeFromSuperview];
    }
    // 暂停气泡定时器，菜单弹出来的时候不弹气泡吵人
    [_bubbleTimer invalidate];
    _bubbleTimer = nil;
    [_bubbleView removeFromSuperview];
    _bubbleView = nil;
    _bubbleLabel = nil;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat girlX = _girlView.center.x;
    CGFloat girlY = _girlView.center.y;
    // 列表样式摆放方向：角色靠右时列表放左边，否则放右边（扇形统一朝屏幕中心展开，无需四方向判断）
    BOOL fromRight = (girlX > screenW - 150);
    // 统一菜单数据源（v6.1.5-10：显示顺序重排——AI 置内圈、隐藏次之，其余按序）
    NSArray *apps = [self _orderedFanMenuApps];
    // v6.1.5-14m：最多显示 15 个（4+5+6 满配），超出截断（AI/隐藏已重排在前，自然保留）
    if (apps.count > 15) apps = [apps subarrayWithRange:NSMakeRange(0, 15)];
    // v6.1.5-8/10：扇形按钮 56pt；孔雀开屏半径 88/172/256（内1 中2 外N-3）
    CGFloat fanBtn = 56.0;
    NSInteger count = apps.count;
    // v6.1.5-14af：样式读取顺序改为 全局文件 > suite > 默认（与滑块一致）——
    // 原只读 suite：App Group 在独立 HUD 进程上权限不可用时恒为 0 → "切换纵向列表没用"
    NSInteger menuStyle = 0;
    NSData *styleData = [NSData dataWithContentsOfFile:@"/var/mobile/Documents/fanmenu_settings.json"];
    if (styleData) {
        NSDictionary *sd = [NSJSONSerialization JSONObjectWithData:styleData options:0 error:nil];
        if ([sd isKindOfClass:[NSDictionary class]] && sd[@"style"]) menuStyle = [sd[@"style"] integerValue];
    }
    NSUserDefaults *stylePrefs = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ai.iosxcode"];
    if ([stylePrefs objectForKey:@"fanMenuStyle"]) menuStyle = [stylePrefs integerForKey:@"fanMenuStyle"];
    BOOL isList = (menuStyle == 1);
    // v6.1.5-14n：菜单参数（图标整体透明度/散开角度/弧度）——读取顺序 全局文件 > suite > 默认
    // 全局文件由主 App 写（/var/mobile/Documents/fanmenu_settings.json），绕开 App Group 权限不确定性
    CGFloat fanAlpha = 1.0, fanSpan = 90.0, fanArc = 1.0;
    NSData *stData = [NSData dataWithContentsOfFile:@"/var/mobile/Documents/fanmenu_settings.json"];
    if (stData) {
        NSDictionary *st = [NSJSONSerialization JSONObjectWithData:stData options:0 error:nil];
        if ([st isKindOfClass:[NSDictionary class]]) {
            if (st[@"alpha"]) fanAlpha = [st[@"alpha"] doubleValue];
            if (st[@"span"]) fanSpan = [st[@"span"] doubleValue];
            if (st[@"arc"]) fanArc = [st[@"arc"] doubleValue];
        }
    }
    NSUserDefaults *menuPrefs = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ai.iosxcode"];
    if ([menuPrefs objectForKey:@"fanMenuAlpha"]) fanAlpha = [menuPrefs doubleForKey:@"fanMenuAlpha"];
    if ([menuPrefs objectForKey:@"fanMenuSpan"]) fanSpan = [menuPrefs doubleForKey:@"fanMenuSpan"];
    if ([menuPrefs objectForKey:@"fanMenuArc"]) fanArc = [menuPrefs doubleForKey:@"fanMenuArc"];
    if (fanAlpha < 0.2) fanAlpha = 0.2; if (fanAlpha > 1.0) fanAlpha = 1.0;
    if (fanSpan < 40) fanSpan = 40; if (fanSpan > 160) fanSpan = 160;
    if (fanArc < 0.7) fanArc = 0.7; if (fanArc > 1.4) fanArc = 1.4;
    // 第一遍：算所有按钮中心
    // v6.1.5-14l：弧带中心点 C = 角色中心沿 centerAng 移到角色轮廓外 30pt——菜单从角色侧面展开（不遮角色），
    // 所有层从 C 起算；提前声明供布局与防叠共用
    CGFloat girlHalfW = (_girlView.frame.size.width > 0) ? _girlView.frame.size.width / 2.0 : 60.0;
    CGFloat centerAngAll = atan2(screenH / 2 - girlY, screenW / 2 - girlX) * 180.0 / M_PI;
    CGFloat centerRadAll = centerAngAll * M_PI / 180;
    CGFloat cx = girlX + cos(centerRadAll) * (girlHalfW + 30);
    CGFloat cy = girlY + sin(centerRadAll) * (girlHalfW + 30);
    NSMutableArray *centers = [NSMutableArray arrayWithCapacity:count];
    for (NSInteger i = 0; i < count; i++) {
        CGFloat x, y;
        if (isList) {
            // v6.1.5-14am：纵向列表=角色侧身纯图标竖排（与扇形同款圆钮，无名字无卡片）
            // 间距64pt 与扇钮直径56+8一致，不叠；y 从角色高度居中向上下排
            CGFloat startY = girlY - (count * 64) / 2;
            CGFloat minYy = 60;
            CGFloat maxYy = screenH - count * 64 - 60;
            if (maxYy < minYy) maxYy = minYy;
            startY = MAX(minYy, MIN(startY, maxYy));
            x = fromRight ? girlX - 64 : girlX + 64;
            y = startY + i * 64;
        } else {
            // v6.1.5-14m：彩虹弧带定稿（用户："第一排4个第二排5个第三排6个，最多15个"）——
            // 每层 4/5/6 逐层+1；超过15个截断只显示15；
            // 半径 115/175/235，间隔 内30°/中22°/外18°（外层更紧凑），每层跨度约90°整齐；
            // 弧距验证：内 115×30°π/180=60pt / 中 175×22°=67pt / 外 235×18°=74pt——均>56pt 按钮不叠
            NSInteger layerCount = (count <= 4) ? 1 : (count <= 9) ? 2 : 3;
            NSInteger caps[4] = {0, 0, 0, 0};
            NSInteger filled = 0;
            for (NSInteger L = 0; L < layerCount; L++) {
                NSInteger cap = 4 + L;
                if (L == layerCount - 1) cap = count - filled;  // 最后一层装剩余（≤6）
                caps[L] = cap;
                filled += cap;
            }
            NSInteger layer = 0, posInLayer = 0, acc = 0;
            for (NSInteger L = 0; L < layerCount; L++) {
                if (i < acc + caps[L]) { layer = L; posInLayer = i - acc; break; }
                acc += caps[L];
            }
            CGFloat radii[4] = {115, 175, 235, 295};
            // v6.1.5-14n：弧度(半径)缩放——用户设置 fanMenuArc 整体缩放层半径
            for (NSInteger L2 = 0; L2 < 4; L2++) radii[L2] = radii[L2] * fanArc;
            CGFloat layerR = radii[layer];
            NSInteger nk = caps[layer];
            CGFloat stepDegArr[4] = {30.0, 30.0, 22.0, 18.0};  // 内层30°→外层18°，外层更紧凑
            CGFloat stepDeg = (layer < 4) ? stepDegArr[layer] : 18.0;
            // v6.1.5-14n：散开角度 = 用户设置值（所有层同一散开角度、层内均分；外层 app 多自然更紧凑）
            CGFloat span = (nk > 1) ? fanSpan : 0;
            // v6.1.5-12：扇面中心始终指向屏幕中心——角色贴边/贴底时外层按钮也朝屏幕中央展开
            CGFloat centerAng = atan2(screenH / 2 - girlY, screenW / 2 - girlX) * 180.0 / M_PI;
            CGFloat startDeg = centerAng - span / 2;
            // 层内均分本层弧：单个数居中，多个均匀铺开
            CGFloat deg = (nk == 1) ? (startDeg + span / 2) : (startDeg + posInLayer * (span / (nk - 1)));
            CGFloat ang = deg * M_PI / 180;
            x = cx + cos(ang) * layerR;
            y = cy + sin(ang) * layerR;
            // 出屏保护（v6.1.5-14k：边界放宽到 15/30）
            x = MAX(15, MIN(screenW - 15, x));
            y = MAX(30, MIN(screenH - 30, y));
        }
        [centers addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
    }
    // v6.1.5-14l：防叠兜底——任意两图标中心距 <58pt（按钮直径56+2）时，把后出现者沿弧外推12pt，最多3轮
    for (NSInteger pass = 0; pass < 3; pass++) {
        BOOL moved = NO;
        for (NSInteger a = 0; a < count; a++) for (NSInteger b = a + 1; b < count; b++) {
            CGPoint pa = [centers[a] CGPointValue];
            CGPoint pb = [centers[b] CGPointValue];
            CGFloat dx = pa.x - pb.x, dy = pa.y - pb.y;
            if (dx * dx + dy * dy < 58.0 * 58.0) {
                CGFloat ang2 = atan2(pb.y - cy, pb.x - cx);  // 沿弧带中心 C 外推
                CGFloat newR = hypot(pb.x - cx, pb.y - cy) + 12;
                CGPoint np = CGPointMake(cx + cos(ang2) * newR, cy + sin(ang2) * newR);
                np.x = MAX(15, MIN(screenW - 15, np.x));
                np.y = MAX(30, MIN(screenH - 30, np.y));
                centers[b] = [NSValue valueWithCGPoint:np];
                moved = YES;
            }
        }
        if (!moved) break;
    }
    // 点空白处关菜单（最底层）
    UIButton *blank = [UIButton buttonWithType:UIButtonTypeCustom];
    blank.frame = self.view.bounds;
    blank.tag = 9000;
    [blank addTarget:self action:@selector(_closeFanMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view insertSubview:blank atIndex:0];
    // v6.1.5-13：去掉毛玻璃大背景面板（用户反馈"大框背景"突兀）——菜单干净无框，
    // 精致感靠按钮本身（圆钮/白边框/真实图标/名称胶囊/弹性动画）
    // 第二遍：创建按钮 + 名称胶囊，逐个弹性入场
    for (NSInteger i = 0; i < count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        NSString *symName = [self _symbolForName:apps[i][@"name"] url:apps[i][@"url"]];
        if (isList) {
            // v6.1.5-14am：纵向列表=角色侧身纯图标圆钮（与扇形同款），无名字无 url 无卡片——
            // 用户"app 不该有名字"+"纵向列表在角色侧身"
            btn.frame = CGRectMake(0, 0, fanBtn, fanBtn);
            btn.layer.cornerRadius = fanBtn / 2;
            btn.backgroundColor = apps[i][@"color"];
            btn.layer.borderWidth = 0;
            btn.layer.shadowColor = [UIColor blackColor].CGColor;
            btn.layer.shadowOpacity = 0.4;
            btn.layer.shadowOffset = CGSizeMake(0, 3);
            btn.layer.shadowRadius = 6;
            UIImage *realIcon = _realAppIcon(apps[i][@"bundleId"]);
            if (realIcon) {
                UIImageView *riv = [[UIImageView alloc] initWithFrame:btn.bounds];
                riv.image = realIcon;
                riv.contentMode = UIViewContentModeScaleAspectFill;
                riv.layer.cornerRadius = fanBtn / 2;
                riv.layer.masksToBounds = YES;
                [btn addSubview:riv];
                btn.backgroundColor = [UIColor clearColor];
            } else {
                UIImage *sym = [UIImage systemImageNamed:symName];
                if (sym) {
                    UIImageView *iv = [[UIImageView alloc] initWithImage:[sym imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24]]];
                    iv.tintColor = [UIColor whiteColor];
                    iv.frame = CGRectMake((fanBtn - 26) / 2, 15, 26, 26);
                    [btn addSubview:iv];
                }
            }
        } else {
            // v6.1.5-9：扇形——纯图标圆钮
            // v6.1.5-14j：图标圆形直接填充满按钮——去掉白色边框环、去掉 wrap 白底环（用户"圆形外面还有一个环"）
            btn.frame = CGRectMake(0, 0, fanBtn, fanBtn);
            btn.layer.cornerRadius = fanBtn / 2;
            btn.backgroundColor = apps[i][@"color"];  // SF Symbol 兜底时用作底色；真实图标填满后置透明
            btn.layer.borderWidth = 0;
            btn.layer.shadowColor = [UIColor blackColor].CGColor;
            btn.layer.shadowOpacity = 0.4;
            btn.layer.shadowOffset = CGSizeMake(0, 3);
            btn.layer.shadowRadius = 6;
            // v6.1.5-8：真实图标优先（自定义 app），SF Symbol 兜底（默认项）
            // v6.1.5-14j：图标 56pt 圆形直接填满整个按钮（无环无边框无白底）
            UIImage *realIcon = _realAppIcon(apps[i][@"bundleId"]);
            if (realIcon) {
                UIImageView *riv = [[UIImageView alloc] initWithFrame:btn.bounds];
                riv.image = realIcon;
                riv.contentMode = UIViewContentModeScaleAspectFill;
                riv.layer.cornerRadius = fanBtn / 2;
                riv.layer.masksToBounds = YES;
                [btn addSubview:riv];
                btn.backgroundColor = [UIColor clearColor];
            } else {
                UIImage *sym = [UIImage systemImageNamed:symName];
                if (sym) {
                    UIImageView *iv = [[UIImageView alloc] initWithImage:[sym imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24]]];
                    iv.tintColor = [UIColor whiteColor];
                    iv.frame = CGRectMake((fanBtn - 26) / 2, 15, 26, 26);
                    [btn addSubview:iv];
                }
            }
        }
        btn.tag = 9000 + i;
        btn.alpha = 0;
        CGPoint c = [centers[i] CGPointValue];
        btn.center = c;
        [btn addTarget:self action:@selector(_fanBtnClick:) forControlEvents:UIControlEventTouchUpInside];
        // v6.1.5-14i：手势双保险——UIButton target-action 在系统级窗口偶发失效时，
        // UITapGestureRecognizer 兜住点击（cancelsTouchesInView=NO 不吞按钮事件）
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_fanBtnTap:)];
        tap.cancelsTouchesInView = NO;
        [btn addGestureRecognizer:tap];
        [self.view addSubview:btn];
        // v6.1.5-14：菜单诊断——记录每个按钮 tag/名称/frame，定位"点不到"是否位置错位
        [self _appendHudLog:[NSString stringWithFormat:@"menu i=%ld name=%@ frame=%@", (long)i, apps[i][@"name"] ?: @"", NSStringFromCGRect(btn.frame)]];
        // v6.1.5-14：去掉扇形名称胶囊（用户要求"不要显示 app 名字"）——扇形纯图标圆钮；
        // 列表卡片自带标题不受影响
        // v6.1.5-14：入场只做 alpha 淡入——不做 scale/位移动画，按钮创建即最终位置尺寸，
        // 动画期间点击区域完整可用（修复"视觉已放大但点不到"的命中错位）
        [UIView animateWithDuration:0.25 delay:0.05 + i*0.04 options:UIViewAnimationOptionCurveEaseOut animations:^{
            btn.alpha = fanAlpha;  // v6.1.5-14n：整体透明度（用户设置）
        } completion:nil];
    }
}

- (void)_fanBtnTap:(UITapGestureRecognizer *)g {
    // v6.1.5-14i：手势保险——转发给按钮点击处理（frame 命中即触发）
    if ([g.view isKindOfClass:[UIButton class]]) [self _fanBtnClick:(UIButton *)g.view];
}

- (void)_fanBtnClick:(UIButton *)btn {
    NSInteger idx = btn.tag - 9000;
    // v6.1.5-14i：手势+按钮事件双保险会重复触发——1.2s 内同按钮只处理一次
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (idx == _lastFanClickIdx && (now - _lastFanClickTime) < 1.2) return;
    _lastFanClickIdx = idx;
    _lastFanClickTime = now;
    [self _closeFanMenu];
    // v6.1.5-10：与 _showFanMenu 共用同一重排数据源（AI 内圈/隐藏次之），点对项不错位
    // v6.1.5-14m：与显示侧同截断到 15，idx 不错位
    NSArray *apps = [self _orderedFanMenuApps];
    if (apps.count > 15) apps = [apps subarrayWithRange:NSMakeRange(0, 15)];
    if (idx < 0 || idx >= (NSInteger)apps.count) return;
    NSDictionary *target = apps[idx];
    NSString *url = target[@"url"] ?: @"";
    NSString *bundleId = target[@"bundleId"] ?: @"";
    // v6.1.5-7：点击诊断日志
    [self _appendHudLog:[NSString stringWithFormat:@"tap idx=%ld name=%@ bid=%@ url=%@", (long)idx, target[@"name"] ?: @"", bundleId, url]];
    if ([url isEqualToString:@"trollagent://hide"]) {
        // 隐藏：缩小成小圆点贴屏幕边缘，不消失，点一下恢复
        [UIView animateWithDuration:0.3 animations:^{
            CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
            CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
            _girlView.transform = CGAffineTransformMakeScale(0.1, 0.1);
            _girlView.center = CGPointMake(screenW - 30, screenH - 100);
            self.view.alpha = 0.7;
        }];
        _isHidden = YES;
        return;
    }
    if ([url isEqualToString:@"trollagent://chat"] || [target[@"name"] isEqualToString:@"AI"]) {
        // AI聊天
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"trollagent://chat"] options:@{} completionHandler:nil];
        return;
    }
    if (bundleId.length > 0) {
        BOOL opened = NO;
        // v6.1.5-14b：点击打开三保险——
        // 1) SBSLaunchApplicationWithIdentifier（TrollStore 生态主流，SpringBoard 服务，实测可靠）
        void *sbHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        if (sbHandle) {
            int (*SBSLaunchFn)(CFStringRef, Boolean) = (int (*)(CFStringRef, Boolean))dlsym(sbHandle, "SBSLaunchApplicationWithIdentifier");
            if (SBSLaunchFn) {
                int sret = SBSLaunchFn((__bridge CFStringRef)bundleId, false);
                opened = (sret == 0);
                [self _appendHudLog:[NSString stringWithFormat:@"open SBS ret=%d bid=%@", sret, bundleId]];
            }
            dlclose(sbHandle);
        }
        // 2) LSApplicationWorkspace openApplicationWithBundleID 兜底
        if (!opened) {
            Class LSWorkspace = NSClassFromString(@"LSApplicationWorkspace");
            id ws = LSWorkspace ? [LSWorkspace performSelector:@selector(defaultWorkspace)] : nil;
            if (ws && [ws respondsToSelector:@selector(openApplicationWithBundleID:)]) {
                id ret = [ws performSelector:@selector(openApplicationWithBundleID:) withObject:bundleId];
                opened = (ret != nil);
                [self _appendHudLog:[NSString stringWithFormat:@"open LSW ret=%@ bid=%@", ret, bundleId]];
            }
        }
        // 3) 主 App 代开（trollagent://open?bid=）——主 App 是 TrollStore 有效签名+launchapplications，
        //    HUD 自身权限万一失效时由主 App 打开
        if (!opened) {
            NSString *bidEnc = [bundleId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
            NSString *mainUrl = [NSString stringWithFormat:@"trollagent://open?bid=%@", bidEnc];
            [self _appendHudLog:[NSString stringWithFormat:@"open mainApp fallback url=%@", mainUrl]];
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:mainUrl] options:@{} completionHandler:^(BOOL ok) {
                if (!ok) [self _showToast:[NSString stringWithFormat:@"打不开 %@", target[@"name"] ?: @"该应用"]];
            }];
        }
    } else if (url.length > 0) {
        // url scheme 打开（AI 聊天/自定义 scheme）
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
    } else {
        [self _showToast:@"该应用未配置打开方式"];
    }
}

// v6.1.5-7：诊断日志追加写 /tmp/hud_fan.log（HUD no-sandbox，/tmp 全局可写）
- (void)_appendHudLog:(NSString *)line {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/hud_fan.log"];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [entry writeToFile:@"/tmp/hud_fan.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// v6.1.5-14：轻提示（点击反馈）——打开失败/未配置时明确告知，避免"点了没反应"
// v6.1.5-14y：先移除旧 toast——原实现每次新建叠加，快速多次提示时多个 toast 叠屏+多个延迟堆积
- (void)_showToast:(NSString *)msg {
    UIView *old = [self.view viewWithTag:9100];
    if (old) [old removeFromSuperview];
    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectZero];
    toast.text = msg;
    toast.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.layer.cornerRadius = 12;
    toast.clipsToBounds = YES;
    CGSize ts = [toast.text sizeWithAttributes:@{NSFontAttributeName: toast.font}];
    CGFloat tw = MIN(ts.width + 28, [UIScreen mainScreen].bounds.size.width - 40);
    toast.frame = CGRectMake(([UIScreen mainScreen].bounds.size.width - tw) / 2, [UIScreen mainScreen].bounds.size.height - 200, tw, 32);
    toast.tag = 9100;
    [self.view addSubview:toast];
    toast.alpha = 0;
    [UIView animateWithDuration:0.22 animations:^{ toast.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; } completion:^(BOOL fin) { [toast removeFromSuperview]; }];
    });
}

- (NSArray *)_readMainAppPrefsFanMenuApps {
    // no-sandbox + platform-application：直接枚举 /var/mobile/Containers/Data/Application/
    // 找主 App（com.trollagent.app）的偏好 plist 读 fanMenuApps（文件级共享，最可靠）
    NSArray *containers = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/mobile/Containers/Data/Application" error:nil];
    for (NSString *cid in containers) {
        NSString *prefPath = [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@/Library/Preferences/com.trollagent.app.plist", cid];
        if (![[NSFileManager defaultManager] fileExistsAtPath:prefPath]) continue;
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefPath];
        if (prefs) {
            NSArray *apps = prefs[@"fanMenuApps"];
            if (apps.count > 0) return apps;
        }
    }
    return nil;
}

// v6.1.5-8：真实 app 图标（TrollStore/TheBall 同款私有 API +[UIImage _applicationIconImageForBundleIdentifier:format:scale:]）
// HUD 进程带 platform-application/no-sandbox 权限，MobileIcons 响应；参数：iPhone format=10、iPad=8、scale=屏幕倍率
static UIImage * _realAppIcon(NSString *bundleId) {
    if (bundleId.length == 0) return nil;
    Class imgCls = NSClassFromString(@"UIImage");
    if (!imgCls) return nil;
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    Method m = class_getClassMethod(imgCls, sel);
    if (!m) return nil;
    typedef UIImage *(*IconFn)(id, SEL, NSString *, NSInteger, double);
    IconFn fn = (IconFn)method_getImplementation(m);
    NSInteger format = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) ? 8 : 10;
    return fn(imgCls, sel, bundleId, format, [UIScreen mainScreen].scale);
}

// v6.1.5-10：孔雀开屏显示顺序——AI 聊天置内圈（最靠近角色）、隐藏次之，其余 app 按原序排外圈
- (NSArray *)_orderedFanMenuApps {
    NSMutableArray *arr = [NSMutableArray arrayWithArray:[self _fanMenuApps]];
    NSInteger aiIdx = -1, hideIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)arr.count; i++) {
        if ([arr[i][@"url"] isEqualToString:@"trollagent://chat"]) aiIdx = i;
        if ([arr[i][@"url"] isEqualToString:@"trollagent://hide"]) hideIdx = i;
    }
    if (aiIdx > 0) {
        id obj = arr[aiIdx];
        [arr removeObjectAtIndex:aiIdx];
        [arr insertObject:obj atIndex:0];
    }
    hideIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)arr.count; i++) {
        if ([arr[i][@"url"] isEqualToString:@"trollagent://hide"]) hideIdx = i;
    }
    if (hideIdx > 0) {
        id obj = arr[hideIdx];
        [arr removeObjectAtIndex:hideIdx];
        [arr insertObject:obj atIndex:1];
    }
    return arr;
}

- (NSArray *)_fanMenuApps {
    // v6.1.5-4：统一菜单数据构建——自定义列表（App Group suite 优先，standard 兜底旧数据）
    // + 无自定义时默认4个 + 固定 AI/隐藏。_showFanMenu 与 _fanBtnClick 都走这里，保证点对项
    // v6.1.5-7：记录数据来源（suite/plist/std/default），写诊断日志到 /tmp/hud_fan.log 定位"自定义不进菜单"卡在哪层
    // v6.1.5-14e：新增全局文件通道 /var/mobile/Documents/fanmenu.json（主 App no-sandbox 写、HUD 读，
    // 不依赖 App Group 在独立 HUD 上的权限确定性）——suite → 全局文件 → 主App容器plist → standard → 默认
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ai.iosxcode"];
    NSArray *savedApps = [prefs arrayForKey:@"fanMenuApps"];
    NSString *src = @"default";
    if (savedApps.count) src = @"suite";
    // v6.1.5-14e：全局文件通道（最不依赖权限：两边都是 no-sandbox，直接读 /var/mobile/Documents）
    if (!savedApps.count) {
        NSData *jdata = [NSData dataWithContentsOfFile:@"/var/mobile/Documents/fanmenu.json"];
        if (jdata) {
            NSArray *jarr = [NSJSONSerialization JSONObjectWithData:jdata options:0 error:nil];
            if ([jarr isKindOfClass:[NSArray class]] && jarr.count) {
                savedApps = jarr;
                src = @"sharedfile";
            }
        }
    }
    // v6.1.5-6：App Group suite 读不到时，no-sandbox 直读主 App 容器偏好文件
    // （TheBall 同款思路：主 App 与悬浮球共享同一数据文件，绕开 App Group 在独立 HUD App 上的权限不确定性）
    if (!savedApps.count) {
        savedApps = [self _readMainAppPrefsFanMenuApps];
        if (savedApps.count) src = @"plist";
    }
    if (!savedApps.count) {
        savedApps = [[NSUserDefaults standardUserDefaults] arrayForKey:@"fanMenuApps"];
        if (savedApps.count) src = @"std";
    }
    NSMutableArray *apps = [NSMutableArray array];
    if (savedApps.count) {
        for (NSDictionary *a in savedApps) {
            // v6.0.30修复：从已安装应用添加的条目只有bundleId没有url，
            // 字典字面量遇nil值直接抛NSInvalidArgumentException崩溃（菜单弹不出）
            NSString *name = a[@"name"] ?: @"应用";
            NSString *url = a[@"url"] ?: @"";
            NSString *bid = a[@"bundleId"] ?: @"";
            [apps addObject:@{
                @"name": name,
                @"url": url,
                @"bundleId": bid,
                @"color": [UIColor systemBlueColor]
            }];
        }
    } else {
        // 默认（与主 App 默认一致；v6.1.5-8 起带 bundleId，点击走 LSApplicationWorkspace，
        // camera:// App-prefs:// 等 scheme 在 iOS 上不存在/被拒，旧默认项点击必"没反应"）
        [apps addObjectsFromArray:@[
            @{@"name":@"微信", @"url":@"weixin://", @"bundleId":@"com.tencent.xin", @"color":[UIColor colorWithRed:0.19 green:0.78 blue:0.32 alpha:1.0]},
            @{@"name":@"抖音", @"url":@"snssdk1128://", @"bundleId":@"com.ss.iphone.ugc.Aweme", @"color":[UIColor blackColor]},
            @{@"name":@"相机", @"url":@"camera://", @"bundleId":@"com.apple.camera", @"color":[UIColor systemTealColor]},
            @{@"name":@"设置", @"url":@"App-prefs://", @"bundleId":@"com.apple.Preferences", @"color":[UIColor grayColor]}
        ]];
    }
    // 最后固定加AI聊天和隐藏
    [apps addObject:@{@"name":@"AI", @"url":@"trollagent://chat", @"bundleId":@"", @"color":[UIColor systemBlueColor]}];
    [apps addObject:@{@"name":@"隐藏", @"url":@"trollagent://hide", @"bundleId":@"", @"color":[UIColor systemRedColor]}];
    // v6.1.5-7：诊断——记录本次菜单数据来源与内容
    NSMutableString *names = [NSMutableString string];
    for (NSDictionary *a in apps) { [names appendFormat:@"%@,", a[@"name"]]; }
    [self _appendHudLog:[NSString stringWithFormat:@"menu src=%@ count=%ld names=%@", src, (long)apps.count, names]];
    return apps;
}

- (void)_closeFanMenu {
    // v6.1.5-9：淡出关闭（按钮点击后菜单优雅收起，再执行启动逻辑）
    NSArray *subs = [NSArray arrayWithArray:self.view.subviews];
    for (UIView *v in subs) {
        if (v.tag >= 9000) v.userInteractionEnabled = NO;
    }
    [UIView animateWithDuration:0.12 animations:^{
        for (UIView *v in subs) {
            if (v.tag >= 9000) v.alpha = 0;
        }
    } completion:^(BOOL finished) {
        for (UIView *v in subs) {
            if (v.tag >= 9000) [v removeFromSuperview];
        }
    }];
    // 恢复气泡定时器
    if (!_isHidden) {
        [self _startBubbleTimer];
    }
}

// v6.0.30：键盘弹出/收起自动隐藏/恢复桌宠
- (void)keyboardWillShow:(NSNotification *)note {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"autoHideWithKeyboard"]) {
        [UIView animateWithDuration:0.2 animations:^{
            self.view.alpha = 0.55;  // v6.1.5-14s：0.2 太透明，调 0.55
        }];
    }
}
- (void)keyboardWillHide:(NSNotification *)note {
    [UIView animateWithDuration:0.2 animations:^{
        // v6.0.30修复：恢复时按当前状态还原——普通状态1.0，隐藏缩小状态0.7，别把隐藏态顶成完全显示
        self.view.alpha = self->_isHidden ? 0.7 : 1.0;
    }];
}

// v6.1.5-14n：轮询键盘全局文件（主 App 写）——覆盖 HUD 收不到键盘通知的场景
- (void)_pollKeyboardFile {
    // 开关：全局文件（设置页写）优先；文件不存在按 HUD 自身 standard 兜底（默认开）
    BOOL enabled = YES;
    NSString *sw = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/auto_hide_keyboard.txt"
                                             encoding:NSUTF8StringEncoding error:nil];
    if (sw.length > 0) enabled = [sw hasPrefix:@"1"];
    if (!enabled) {
        // v6.1.5-14ac：开关关闭也要恢复 alpha——原直接 return，键盘弹出时关开关会卡在半透明不恢复
        CGFloat t = _isHidden ? 0.7 : 1.0;
        if (fabs(self.view.alpha - t) > 0.05) {
            [UIView animateWithDuration:0.2 animations:^{
                self.view.alpha = t;
            }];
        }
        return;
    }
    BOOL vis = NO;
    NSString *kv = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/keyboard_state.json"
                                            encoding:NSUTF8StringEncoding error:nil];
    if (kv.length > 0) vis = [kv hasPrefix:@"1"];
    // v6.1.5-14s：键盘弹出时透明降到 0.55（原 0.2 太透明，用户反馈几乎看不见）
    CGFloat target = vis ? 0.55 : (self->_isHidden ? 0.7 : 1.0);
    if (fabs(self.view.alpha - target) > 0.05) {
        [UIView animateWithDuration:0.2 animations:^{
            self.view.alpha = target;
        }];
    }
}

// v6.1.5-14p：emoji → UIImage（粒子素材，零图片资源）
// v6.1.5-14q：改直接字符串绘制——drawViewHierarchyInRect 要求视图在窗口树里，
// 独立 HUD 进程里 UILabel 不在 window 上会生成空图 → 粒子完全不可见（用户反馈看不到粒子）
// v6.1.5-14v：用户要"柔和光粒子"——弃用 emoji，改径向渐变圆形（中心亮→边缘透明）柔光光斑，
// 白色素材 + cell.color 按场景染色（充电白蓝/深夜银白淡蓝/傍晚暖金）
static UIImage *softParticleImage(CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat locs[3] = {0.0f, 0.55f, 1.0f};
    CGFloat comps[12] = {
        1.0f, 1.0f, 1.0f, 1.0f,      // 中心：纯白高亮
        1.0f, 1.0f, 1.0f, 0.55f,     // 中间：半透
        1.0f, 1.0f, 1.0f, 0.0f       // 边缘：完全透明（柔光羽化）
    };
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 3);
    CGContextDrawRadialGradient(ctx, grad,
                                CGPointMake(size / 2, size / 2), 0,
                                CGPointMake(size / 2, size / 2), size / 2,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// v6.1.5-14p：环境氛围初始化——粒子层挂到根视图，60s 定时刷新（小时+充电态）
// v6.1.5-14q：去掉光晕（用户反馈"大圆环"不好看），只留粒子
- (void)_setupAmbient {
    if (!_particleLayer) {
        _particleLayer = [CAEmitterLayer layer];
        _particleLayer.emitterMode = kCAEmitterLayerVolume;
        _particleLayer.emitterSize = CGSizeMake(70, 10);
        [self.view.layer insertSublayer:_particleLayer below:_girlView.layer];  // 粒子在角色后方
    }
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [self _updateAmbient];
    _ambientTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(_updateAmbient) userInfo:nil repeats:YES];
}

// v6.1.5-14p/q：环境决策——按小时选粒子，充电叠加粒子；粒子跟随角色位置（无光晕）
// v6.1.5-14v：场景→颜色（素材统一柔白光点，cell.color 染色）
// v6.1.5-14am：白天也出粒子（淡白柔光低密度）——用户"一直没见过粒子"根因是白天无粒子被 _clearParticles 清空
- (void)_updateAmbient {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSInteger hour = [cal component:NSCalendarUnitHour fromDate:[NSDate date]];
    NSMutableArray<UIColor *> *colors = [NSMutableArray array];
    NSInteger bucket = 0;   // 白天：淡白柔光（低密度，白墙上也能看出光晕）
    if (hour >= 21 || hour < 6) {
        bucket = 2;  // 深夜：冷银白 + 淡蓝，静谧萤光
        [colors addObject:[UIColor colorWithWhite:0.92 alpha:1.0]];
        [colors addObject:[UIColor colorWithRed:0.72 green:0.83 blue:1.0 alpha:1.0]];
    } else if (hour >= 17 && hour < 19) {
        bucket = 1;  // 傍晚：暖金余晖
        [colors addObject:[UIColor colorWithRed:1.0 green:0.85 blue:0.55 alpha:1.0]];
    } else {
        // v6.1.5-14am：白天（6-17点）淡白柔光粒子——低密度但可见，满足"柔和光粒子"全天可看
        [colors addObject:[UIColor colorWithWhite:1.0 alpha:1.0]];
        [colors addObject:[UIColor colorWithRed:0.85 green:0.92 blue:1.0 alpha:1.0]];
    }
    BOOL charging = ([UIDevice currentDevice].batteryState == UIDeviceBatteryStateCharging ||
                     [UIDevice currentDevice].batteryState == UIDeviceBatteryStateFull);
    if (charging) {
        bucket = 3;  // 充电：明亮白 + 浅蓝，能量感
        [colors addObject:[UIColor colorWithRed:0.95 green:0.98 blue:1.0 alpha:1.0]];
        [colors addObject:[UIColor colorWithRed:0.7 green:0.85 blue:1.0 alpha:1.0]];
    }
    // 漂浮时长只在环境时段切换时重置（避免每 60s 打断漂浮动画）
    // v6.1.5-14ac：趴墙/拖拽中不重置漂浮——原无条件 _startFloatWithDuration 会在
    // 底部/侧边趴墙时重新加上上下漂浮动画，与趴墙（底部呼吸/静止贴墙）冲突
    if (_ambientBucket != bucket) {
        _ambientBucket = bucket;
        if (!_onSideWall && !_onBottomWall && !_isDragging) {
            if (bucket == 2) [self _startFloatWithDuration:2.6f];  // 深夜入睡慢呼吸
            else [self _startFloatWithDuration:1.3f];
        }
    }
    // v6.1.5-14ap：粒子开关——读全局文件（设置页"可爱助手→其他→粒子特效"写），
    // 关闭则清空颜色数组 → 走 else _clearParticles；漂浮（入睡呼吸）不受影响
    BOOL particleOn = YES;
    NSString *pval = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/particle_enabled.txt"
                                               encoding:NSUTF8StringEncoding error:nil];
    if (pval.length > 0) particleOn = [pval hasPrefix:@"1"];
    if (!particleOn) [colors removeAllObjects];
    if (colors.count) {
        [self _setParticles:colors];
    } else {
        [self _clearParticles];
    }
    [self _refreshAmbientPosition];
}

// v6.1.5-14p：粒子跟随角色位置（拖拽/吸附后调用）
- (void)_refreshAmbientPosition {
    if (_particleLayer) {
        _particleLayer.emitterPosition = CGPointMake(_girlView.center.x,
                                                     _girlView.center.y - _girlView.frame.size.height / 2);
        _particleLayer.emitterSize = CGSizeMake(_girlView.frame.size.width * 0.5 + 30, 10);
    }
}

// v6.1.5-14p/q：设置粒子（上飘粒）
// v6.1.5-14v：柔和光点版——柔光渐变圆 + cell.color 染色；光点不旋转、缓慢淡出，更柔和
// v6.1.5-14aa：持有颜色数组 _particleColors（cell.color 为 assign，保证 UIColor 存活、CGColor 不悬垂）
- (void)_setParticles:(NSArray<UIColor *> *)colors {
    if (!_particleLayer) {
        _particleLayer = [CAEmitterLayer layer];
        _particleLayer.emitterMode = kCAEmitterLayerVolume;
        _particleLayer.emitterSize = CGSizeMake(70, 10);
        [self.view.layer insertSublayer:_particleLayer below:_girlView.layer];  // 粒子在角色后方
    }
    _particleColors = colors;
    NSMutableArray *cells = [NSMutableArray array];
    UIImage *dotImg = softParticleImage(24);
    for (UIColor *col in colors) {
        CAEmitterCell *cell = [CAEmitterCell emitterCell];
        cell.contents = (id)dotImg.CGImage;
        cell.color = col.CGColor;
        cell.birthRate = 2.2;         // v6.1.5-14ao：3.2→2.2（14am 提太高像蒸汽机，回调）
        cell.lifetime = 7;
        cell.velocity = 20;
        cell.velocityRange = 18;
        cell.yAcceleration = -6;          // 轻柔上飘（放缓）
        cell.emissionRange = M_PI * 2;
        cell.scale = 0.5;             // v6.1.5-14ao：0.75→0.5（光点调小，柔和不抢眼）
        cell.scaleRange = 0.22;
        cell.scaleSpeed = -0.015;         // 越飘越小
        cell.alphaSpeed = -0.07;          // 缓慢淡出
        cell.spin = 0;                    // 光点不旋转
        cell.spinRange = 0;
        [cells addObject:cell];
    }
    if (!cells.count) { [self _clearParticles]; return; }
    _particleLayer.emitterCells = cells;
}
- (void)_clearParticles {
    [_particleLayer removeFromSuperlayer];
    _particleLayer = nil;
    _particleColors = nil;   // v6.1.5-14aa：清粒子时释放颜色持有
}

@end
