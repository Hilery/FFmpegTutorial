//
//  MR0x22ViewController.m
//  FFmpegTutorial-iOS
//
//  Created by qianlongxu on 2020/7/16.
//  Copyright © 2020 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//
//

#import "MR0x22ViewController.h"
#import <FFmpegTutorial/FFPlayer0x20.h>
#import "MRRWeakProxy.h"
#import <GLKit/GLKit.h>
#import "MR0x22VideoRenderer.h"
#import "MR0x22AudioRenderer.h"

@interface MR0x22ViewController ()<UITextViewDelegate,FFPlayer0x20Delegate>

@property (weak, nonatomic) IBOutlet UITextView *textView;
@property (weak, nonatomic) IBOutlet UIActivityIndicatorView *indicatorView;
@property (assign, nonatomic) NSInteger ignoreScrollBottom;
@property (weak, nonatomic) NSTimer *timer;
@property (assign) MR_PACKET_SIZE pktSize;

@property (nonatomic, strong) FFPlayer0x20 *player;
@property (weak, nonatomic) IBOutlet MR0x22VideoRenderer *renderView;
@property (nonatomic, strong) MR0x22AudioRenderer *audioRender;

@end

@implementation MR0x22ViewController

- (void)dealloc
{
    if (self.timer) {
        [self.timer invalidate];
        self.timer = nil;
    }
    
    if (self.player) {
        [self.player asyncStop];
        self.player = nil;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    [self.indicatorView startAnimating];
    self.textView.delegate = self;
    self.textView.layoutManager.allowsNonContiguousLayout = NO;
    self.renderView.contentMode = UIViewContentModeScaleAspectFit;
    
    FFPlayer0x20 *player = [[FFPlayer0x20 alloc] init];
    player.contentPath = KTestVideoURL1;
    
    __weakSelf__
    [player onError:^{
        __strongSelf__
        [self.indicatorView stopAnimating];
        self.textView.text = [self.player.error localizedDescription];
        self.player = nil;
        [self.timer invalidate];
        self.timer = nil;
    }];
    player.supportedPixelFormats  = MR_PIX_FMT_MASK_NV12;
    player.supportedSampleFormats = MR_SAMPLE_FMT_MASK_AUTO;
//    for test fmt.
//    player.supportedSampleFormats = MR_SAMPLE_FMT_MASK_S16 | MR_SAMPLE_FMT_MASK_FLT;
//    player.supportedSampleFormats = MR_SAMPLE_FMT_MASK_S16P;
//    player.supportedSampleFormats = MR_SAMPLE_FMT_MASK_FLTP;
    
    //设置采样率，如果播放之前知道音频的采样率，可以设置成实际的值，可避免播放器内部转换！
    int sampleRate = [MR0x22AudioRenderer setPreferredSampleRate:44100];
    player.supportedSampleRate = sampleRate;
    
    player.delegate = self;
    [player prepareToPlay];
    [player play];
    self.player = player;
    [self prepareTickTimerIfNeed];
}

- (void)prepareTickTimerIfNeed
{
    if (self.timer && ![self.timer isValid]) {
        return;
    }
    MRRWeakProxy *weakProxy = [MRRWeakProxy weakProxyWithTarget:self];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:weakProxy selector:@selector(onTimer:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.timer = timer;
}

- (void)playAudio
{
    [self.audioRender paly];
}

- (void)reveiveFrameToRenderer:(CVPixelBufferRef)img
{
    CVPixelBufferRetain(img);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self.renderView displayPixelBuffer:img];
        CVPixelBufferRelease(img);
        
        static bool started = false;
        if (!started) {
            [self playAudio];
            started = true;
        }
    });
}

- (void)onInitAudioRender:(MRSampleFormat)fmt
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self setupAudioRender:fmt];
    });
}

- (void)setupAudioRender:(MRSampleFormat)fmt
{
    self.audioRender = [MR0x22AudioRenderer new];
    [self.audioRender setPreferredAudioQueue:YES];
    [self.audioRender active];
    //播放器使用的采样率
    [self.audioRender setupWithFmt:fmt sampleRate:self.player.supportedSampleRate];
    __weakSelf__
    [self.audioRender onFetchPacketSample:^UInt32(uint8_t * _Nonnull buffer, UInt32 bufferSize) {
        __strongSelf__
        UInt32 filled = [self.player fetchPacketSample:buffer wantBytes:bufferSize];
        return filled;
    }];
    
    [self.audioRender onFetchPlanarSample:^UInt32(uint8_t * _Nonnull left, UInt32 leftSize, uint8_t * _Nonnull right, UInt32 rightSize) {
        __strongSelf__
        UInt32 filled = [self.player fetchPlanarSample:left leftSize:leftSize right:right rightSize:rightSize];
        return filled;
    }];
}

- (void)onTimer:(NSTimer *)sender
{
    MR_PACKET_SIZE pktSize = [self.player peekPacketBufferStatus];
    if (0 == mr_packet_size_equal(self.pktSize, pktSize)) {
        return;
    }
    
    if ([self.indicatorView isAnimating]) {
        [self.indicatorView stopAnimating];
    }
    
    NSString *frmMsg = [NSString stringWithFormat:@"[Frame] audio(%002d)，video(%002d)",self.player.audioFrameCount,self.player.videoFrameCount];
    
    NSString *pktMsg = nil;
    if (mr_packet_size_equal_zero(pktSize)) {
        pktMsg = @"Packet Buffer is Empty";
    } else {
        pktMsg = [NSString stringWithFormat:@" [Packet] audio(%02d)，video(%02d)",pktSize.audio_pkt_size,pktSize.video_pkt_size];
    }
    self.pktSize = pktSize;
    [self appendMsg:[frmMsg stringByAppendingString:pktMsg]];
    
    if (self.ignoreScrollBottom > 0) {
        self.ignoreScrollBottom --;
    } else {
        [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length, 1)];
    }
}

- (void)appendMsg:(NSString *)txt
{
    self.textView.text = txt;//[self.textView.text stringByAppendingFormat:@"\n%@",txt];
}

//滑动时就暂停自动滚到到底部
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    self.ignoreScrollBottom = NSIntegerMax;
}

//松开手了，不需要减速就当即设定5s后自动滚动
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (!decelerate) {
        self.ignoreScrollBottom = 5;
    }
}

//需要减速时，就在停下来之后设定5s后自动滚动
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    self.ignoreScrollBottom = 5;
}

@end
