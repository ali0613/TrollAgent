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
    int _emojiTimer;      // 点击表情显示计时
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
    int _climbIdx;              // 攀爬帧序号
    UILabel *_bubbleLabel;       // v6.0.27：侧边趴墙卡通聊天气泡文字
    UIView *_bubbleView;         // v6.0.28：卡通气泡背景（带小尾巴）
    NSTimer *_bubbleTimer;       // 气泡定时弹出计时器
    BOOL _onSideWall;           // 是否在左右侧边趴墙
    NSString *_charPrefix;      // v6.0.27：当前角色前缀（rabit/girl/cat）
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
        if (isCat)         { _snapReachH = 72.0f; _snapReachV = 85.0f; }   // 猫娘(1.3) 按1.3/1.4比例缩小吸附范围
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

    // 呼吸动画（idle 缩放循环）
    [self _startBreathing];

    // v6.0.8：待机自动切换表情（空闲时随机眨眼/挥手/歪头等）
    [self _scheduleAutoMood];

    // 拖动 + 点击
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_pan:)];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap:)];
    [_girlView addGestureRecognizer:pan];
    [_girlView addGestureRecognizer:tap];
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
- (void)_scheduleAutoMood {
    if (!_moodFrames.count || _moodShowing) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_autoMoodPaused || self->_isDragging || self->_moodShowing) { [self _scheduleAutoMood]; return; }
        if (self->_girlView.image == self->_wallImage || self->_girlView.image == self->_wallImageV) { [self _scheduleAutoMood]; return; }
        if (self->_girlView.image != self->_idleFrames.firstObject) { [self _scheduleAutoMood]; return; }
        NSUInteger idx = self->_moodSeqIndex % self->_moodFrames.count;
        self->_moodSeqIndex = (self->_moodSeqIndex + 1) % self->_moodFrames.count;
        UIImage *m = self->_moodFrames[idx];
        if (!m) { [self _scheduleAutoMood]; return; }
        self->_moodShowing = YES;
        self->_girlView.image = m;
        [self _setFrameForImage:m];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_moodShowing = NO;
            if (!self->_isDragging && !self->_autoMoodPaused &&
                self->_girlView.image != self->_idleFrames.firstObject &&
                self->_girlView.image != self->_wallImage && self->_girlView.image != self->_wallImageV) {
                self->_girlView.image = self->_idleFrames.firstObject;
                self->_girlView.transform = CGAffineTransformIdentity;
                [self _setFrameForImage:self->_idleFrames.firstObject];
            }
            [self _scheduleAutoMood];
        });
    });
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
        [self _stopClimbTimer];    // v6.0.29：拖动时立刻停止所有攀爬
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
                // 恢复站立idle，把缩放改回1.0
                if (_idleFrames.firstObject) {
                    _girlView.transform = CGAffineTransformIdentity;
                    _girlView.image = _idleFrames.firstObject;
                    [self _setFrameForImage:_idleFrames.firstObject];
                    [self _startBreathing];   // 恢复胸部呼吸动效
                }
                _falling = NO;
            }];
        } else {
            // ✅ 其他位置松手 → 走原来的贴边吸附逻辑（保留左右趴墙、底部趴墙等所有原有功能，每个角色独立配置）
            [self _snapToEdge];
        }
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

// v6.0.8：松手吸附到最近屏幕边缘（<threshold 才算）并切换扒墙姿势（企鹅趴墙探头）
// 顶/底（水平边）用水平墙沿图 _wallImage；左/右（垂直边）用竖直墙沿图 _wallImageV。
- (void)_snapToEdge {
    [self _setAnchorY:0.5f];   // v6.0.18：趴墙→中心锚点（趴墙/悬浮不做胸部锚点）
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
    
    // v6.0.26：左右边缘趴墙时，随机启动自动攀爬（10分钟内3-5次，不要太频繁）
    if ((minD == dL || minD == dR) && _climbFrames.count >= 2) {
        [self _stopClimbTimer];
        // 第一次延迟30-60秒后开始攀爬
        NSTimeInterval delay = 30.0 + arc4random_uniform(30000) / 1000.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self _startClimbing];
        });
    }
    
    // v6.0.27：左右侧边趴墙时启动气泡，其他位置停止气泡
    if (minD == dL || minD == dR) {
        _onSideWall = YES;
        [self _startBubbleTimer];
        // v6.0.29：左右墙翻转角色朝向——左墙朝左，右墙朝右
        if (minD == dL) {
            _girlView.transform = CGAffineTransformMakeScale(-1, 1);
        } else {
            _girlView.transform = CGAffineTransformIdentity;
        }
    } else {
        _onSideWall = NO;
        [self _stopBubbleTimer];
        // 离开侧边墙恢复正常朝向
        _girlView.transform = CGAffineTransformIdentity;
    }
}

// v6.0.27：启动气泡定时器
- (void)_startBubbleTimer {
    [self _stopBubbleTimer];
    // v6.0.28：隔30-60秒弹一次气泡，不要太频繁
    NSTimeInterval interval = 30.0 + arc4random_uniform(30000) / 1000.0;
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
}

// v6.0.27：显示随机气泡
- (void)_showRandomBubble {
    if (!_onSideWall || _isDragging || _isClimbing || _falling) return;
    
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
    
    // 用CAShapeLayer画小尾巴（在气泡底部中间，朝下指向角色头）
    UIBezierPath *tailPath = [UIBezierPath bezierPath];
    CGFloat tailX = bubbleW / 2;
    [tailPath moveToPoint:CGPointMake(tailX - tailW/2, bubbleH)];
    [tailPath addLineToPoint:CGPointMake(tailX, bubbleH + tailH)];
    [tailPath addLineToPoint:CGPointMake(tailX + tailW/2, bubbleH)];
    [tailPath closePath];
    
    CAShapeLayer *tailLayer = [CAShapeLayer layer];
    tailLayer.path = tailPath.CGPath;
    // v6.0.28：尾巴颜色跟着气泡样式走
    if (bubbleStyle == 3) {
        tailLayer.fillColor = [UIColor systemYellowColor].CGColor;
        tailLayer.strokeColor = [UIColor blackColor].CGColor;
    } else if (bubbleStyle == 2) {
        tailLayer.fillColor = [UIColor whiteColor].CGColor;
        tailLayer.strokeColor = [UIColor blackColor].CGColor;
    } else if (bubbleStyle == 1) {
        tailLayer.fillColor = [UIColor systemPinkColor].CGColor;
        tailLayer.strokeColor = [UIColor clearColor].CGColor;
    } else {
        tailLayer.fillColor = [UIColor whiteColor].CGColor;
        tailLayer.strokeColor = [UIColor systemPinkColor].CGColor;
    }
    tailLayer.lineWidth = 2;
    [_bubbleView.layer addSublayer:tailLayer];
    
    if (!_bubbleView.superview) {
        [self.view addSubview:_bubbleView];
    }
    
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
        }];
    }];
}

// v6.0.26：开始自动攀爬
- (void)_startClimbing {
    if (_isClimbing || _isDragging || _falling) return;
    if (!_climbFrames.count) return;
    
    // v6.0.29：必须在左右侧边墙才启动攀爬，底部/顶部不爬
    CGSize v = [UIScreen mainScreen].bounds.size;
    CGPoint c = _girlView.center;
    CGFloat dL = c.x, dR = v.width - c.x, dT = c.y, dB = v.height - c.y;
    CGFloat minD = MIN(MIN(dL, dR), MIN(dT, dB));
    if (minD != dL && minD != dR) return;   // 不是左右墙，不爬
    
    _isClimbing = YES;
    _climbIdx = 0;
    
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
    [self _setFrameForImage:cf];
    
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
        [self _setFrameForImage:nextFrame];
        
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
        _girlView.center = c;
    }];
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
    NSTimeInterval nextDelay = 120.0 + arc4random_uniform(60000) / 1000.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(nextDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // v6.0.29：自动再爬之前检查是不是还在左右墙，不在就不爬
        CGSize v = [UIScreen mainScreen].bounds.size;
        CGPoint c = _girlView.center;
        CGFloat dL = c.x, dR = v.width - c.x, dT = c.y, dB = v.height - c.y;
        CGFloat minD = MIN(MIN(dL, dR), MIN(dT, dB));
        if (minD == dL || minD == dR) {
            [self _startClimbing];
        }
    });
}

- (void)_stopClimbTimer {
    [_climbTimer invalidate];
    _climbTimer = nil;
    _isClimbing = NO;
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
- (void)_tap:(UITapGestureRecognizer *)g {
    if (_isDragging) return;
    // v6.0.8：从扒墙状态点击 → 直接恢复站立待机（不切表情）
    if ((_girlView.image == _wallImage || _girlView.image == _wallImageV) && _idleFrames.firstObject) {
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
- (void)_showFanMenu {
    // 先关掉所有旧菜单按钮（统一tag=9000）
    for (UIView *v in self.view.subviews) {
        if (v.tag >= 9000 && v.tag < 9100) [v removeFromSuperview];
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
    // 判断方向：永远朝屏幕中间弹
    BOOL fromBottom = (girlY > screenH - 200);
    BOOL fromTop = (girlY < 150);
    BOOL fromLeft = (girlX < 150);
    BOOL fromRight = (girlX > screenW - 150);
    // 从UserDefaults读取自定义应用列表，默认4个常用
    NSArray *savedApps = [[NSUserDefaults standardUserDefaults] arrayForKey:@"fanMenuApps"];
    NSMutableArray *apps = [NSMutableArray array];
    if (savedApps.count) {
        for (NSDictionary *a in savedApps) {
            [apps addObject:@{
                @"name": a[@"name"],
                @"url": a[@"url"],
                @"color": [UIColor systemBlueColor]
            }];
        }
    } else {
        // 默认
        [apps addObjectsFromArray:@[
            @{@"name":@"微信", @"url":@"weixin://", @"color":[UIColor colorWithRed:0.19 green:0.78 blue:0.32 alpha:1.0]},
            @{@"name":@"抖音", @"url":@"snssdk1128://", @"color":[UIColor blackColor]},
            @{@"name":@"设置", @"url":@"App-prefs://", @"color":[UIColor grayColor]}
        ]];
    }
    // 最后固定加AI聊天和隐藏
    [apps addObject:@{@"name":@"AI", @"url":@"trollagent://chat", @"color":[UIColor systemBlueColor]}];
    [apps addObject:@{@"name":@"隐藏", @"url":@"trollagent://hide", @"color":[UIColor systemRedColor]}];
    CGFloat radius = 110;
    NSInteger count = apps.count;
    NSInteger menuStyle = [[NSUserDefaults standardUserDefaults] integerForKey:@"fanMenuStyle"];
    for (NSInteger i = 0; i < count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, 0, 56, 56);
        btn.layer.cornerRadius = 28;
        btn.backgroundColor = apps[i][@"color"];
        btn.titleLabel.font = [UIFont systemFontOfSize:12];
        [btn setTitle:apps[i][@"name"] forState:UIControlStateNormal];
        btn.tag = 9000 + i;
        btn.alpha = 0;
        CGFloat x, y;
        if (menuStyle == 1) {
            // 纵向列表样式：垂直排列，在角色右侧（如果在右边缘就左侧）
            CGFloat startY = girlY - (count * 64)/2;
            CGFloat listX = fromRight ? girlX - 80 : girlX + 80;
            x = listX;
            y = startY + i * 64;
        } else {
            // 扇形样式：按角度算，count=1的时候不除以0
            CGFloat angle;
            CGFloat step = (count > 1) ? (120.0/(count-1)) : 0;
            if (fromBottom) {
                angle = (-150 + step*i) * M_PI/180;
            } else if (fromTop) {
                angle = (30 + step*i) * M_PI/180;
            } else if (fromLeft) {
                angle = (-60 + step*i) * M_PI/180;
            } else {
                angle = (120 + step*i) * M_PI/180;
            }
            x = girlX + cos(angle)*radius;
            y = girlY + sin(angle)*radius;
        }
        btn.center = CGPointMake(x, y);
        [btn addTarget:self action:@selector(_fanBtnClick:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:btn];
        [UIView animateWithDuration:0.3 animations:^{
            btn.alpha = 1.0;
        }];
    }
    // 点空白处关菜单
    UIButton *blank = [UIButton buttonWithType:UIButtonTypeCustom];
    blank.frame = self.view.bounds;
    blank.tag = 9000;
    [blank addTarget:self action:@selector(_closeFanMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view insertSubview:blank atIndex:0];
}

- (void)_fanBtnClick:(UIButton *)btn {
    NSInteger idx = btn.tag - 9000;
    [self _closeFanMenu];
    // 读取应用列表
    NSArray *savedApps = [[NSUserDefaults standardUserDefaults] arrayForKey:@"fanMenuApps"];
    NSInteger customCount = savedApps.count ?: 3;
    if (idx == customCount + 1) {
        // 最后一个是隐藏：缩小成小圆点贴屏幕边缘，不消失，点一下恢复
        [UIView animateWithDuration:0.3 animations:^{
            CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
            CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
            _girlView.transform = CGAffineTransformMakeScale(0.1, 0.1);
            _girlView.center = CGPointMake(screenW - 30, screenH - 100);
            self.view.alpha = 0.7;
        }];
        // 记下来现在是隐藏状态
        _isHidden = YES;
        return;
    }
    if (idx == customCount) {
        // 倒数第二个是AI聊天
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"trollagent://chat"] options:@{} completionHandler:nil];
        return;
    }
    // 自定义应用
    if (idx < savedApps.count) {
        // 优先用bundleId直接打开（新添加的应用）
        NSString *bundleId = savedApps[idx][@"bundleId"];
        if (bundleId.length > 0) {
            // 用LSApplicationWorkspace直接打开，不用URL scheme
            Class LSWorkspace = NSClassFromString(@"LSApplicationWorkspace");
            id ws = [LSWorkspace performSelector:@selector(defaultWorkspace)];
            [ws performSelector:@selector(openApplicationWithBundleID:) withObject:bundleId];
        } else {
            // 兼容旧的url scheme
            NSString *url = savedApps[idx][@"url"];
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
        }
    }
}

- (void)_closeFanMenu {
    for (UIView *v in self.view.subviews) {
        if (v.tag >= 9000) {
            [v removeFromSuperview];
        }
    }
    // 恢复气泡定时器
    if (!_isHidden) {
        [self _startBubbleTimer];
    }
}

- (void)_resetAfterEmoji {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_isDragging) {
            self->_girlView.image = self->_idleFrames.firstObject;
            self->_girlView.transform = CGAffineTransformIdentity;
            [self _setFrameForImage:self->_idleFrames.firstObject];
        }
    });
}

// v6.0.30：键盘弹出/收起自动隐藏/恢复桌宠
- (void)keyboardWillShow:(NSNotification *)note {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"autoHideWithKeyboard"]) {
        [UIView animateWithDuration:0.2 animations:^{
            self.view.alpha = 0.2;
        }];
    }
}
- (void)keyboardWillHide:(NSNotification *)note {
    [UIView animateWithDuration:0.2 animations:^{
        self.view.alpha = 1.0;
    }];
}

@end
