//
//  MR0x21ViewController.m
//  FFmpegTutorial-iOS
//
//  Created by qianlongxu on 2020/7/14.
//  Copyright © 2020 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//
//

#import "MR0x21ViewController.h"
#import <FFmpegTutorial/FFPlayer0x20.h>
#import "MRRWeakProxy.h"
#import <GLKit/GLKit.h>
#import "MR0x21VideoRenderer.h"
#import <AVFoundation/AVFoundation.h>

#define QUEUE_BUFFER_SIZE 3
#define MIN_SIZE_PER_FRAME 4096

//将音频裸流PCM写入到文件
#define DEBUG_RECORD_PCM_TO_FILE 0


@interface MR0x21ViewController ()<UITextViewDelegate,FFPlayer0x20Delegate>
{
    #if DEBUG_RECORD_PCM_TO_FILE
        FILE * file_pcm_l;
    #endif
    AudioQueueBufferRef audioQueueBuffers[QUEUE_BUFFER_SIZE];
}

@property (nonatomic, strong) FFPlayer0x20 *player;
@property (weak, nonatomic) IBOutlet UITextView *textView;
@property (weak, nonatomic) IBOutlet UIActivityIndicatorView *indicatorView;
@property (weak, nonatomic) IBOutlet MR0x21VideoRenderer *renderView;

@property (assign, nonatomic) NSInteger ignoreScrollBottom;
@property (weak, nonatomic) NSTimer *timer;
@property (assign) MR_PACKET_SIZE pktSize;

//声音大小
@property (nonatomic,assign) float outputVolume;
//最终音频格式（采样深度）
@property (nonatomic,assign) MRSampleFormat finalSampleFmt;
//音频渲染
@property (nonatomic,assign) AudioQueueRef audioQueue;
//音频信息结构体
@property (nonatomic,assign) AudioStreamBasicDescription outputFormat;
//采样率
@property (nonatomic,assign) int targetSampleRate;

@end

@implementation MR0x21ViewController

- (void)dealloc
{
    if(_audioQueue){
        AudioQueueDispose(_audioQueue, YES);
        _audioQueue = NULL;
    }
    
    #if DEBUG_RECORD_PCM_TO_FILE
        fclose(file_pcm_l);
    #endif
    
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
    //设置采样率
    [[AVAudioSession sharedInstance] setPreferredSampleRate:44100 error:nil];
    self.targetSampleRate = (int)[[AVAudioSession sharedInstance] sampleRate];
    
#if DEBUG_RECORD_PCM_TO_FILE
    if (file_pcm_l == NULL) {
        const char *l = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"L.pcm"]UTF8String];
        NSLog(@"%s",l);
        file_pcm_l = fopen(l, "wb+");
    }
#endif
    
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
    
    player.supportedSampleFormats = MR_SAMPLE_FMT_MASK_S16 | MR_SAMPLE_FMT_MASK_FLT;
//    not support planar fmt.
//    player.supportedSampleFormats = MR_SAMPLE_FMT_MASK_S16P;
//    player.supportedSampleFormats = MR_SAMPLE_FMT_MASK_FLTP;
    
    player.supportedSampleRate    = self.targetSampleRate;
    
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
    for(int i = 0; i < QUEUE_BUFFER_SIZE;i++){
        AudioQueueBufferRef ref = self->audioQueueBuffers[i];
        [self renderFramesToBuffer:ref queue:self.audioQueue];
    }
    
    OSStatus status = AudioQueueStart(self.audioQueue, NULL);
    NSAssert(noErr == status, @"AudioOutputUnitStart");
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupAudioRender:fmt];
    });
}

- (void)setupAudioRender:(MRSampleFormat)fmt
{
    _outputVolume = [[AVAudioSession sharedInstance]outputVolume];
        
    {
        [[AVAudioSession sharedInstance]setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker error:nil];
        //        [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(audioRouteChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
        //        [[AVAudioSession sharedInstance]addObserver:self forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew context:nil];
        
        [[AVAudioSession sharedInstance]setActive:YES error:nil];
    }
    
    {
        // ----- Audio Queue Setup -----
        
        _outputFormat.mSampleRate = _targetSampleRate;
        _outputFormat.mChannelsPerFrame = 2;
        _outputFormat.mFormatID = kAudioFormatLinearPCM;
        _outputFormat.mReserved = 0;
        
        bool isFloat  = MR_Sample_Fmt_Is_FloatX(fmt);
        bool isS16    = MR_Sample_Fmt_Is_S16X(fmt);
        bool isPacket = MR_Sample_Fmt_Is_Packet(fmt);
        NSAssert(isPacket, @"Audio Queue Support packet fmt only!");
        
        if (isS16){
            _outputFormat.mFormatFlags |= kAudioFormatFlagIsSignedInteger;
            _outputFormat.mFramesPerPacket = 1;
            _outputFormat.mBitsPerChannel = sizeof(SInt16) * 8;
        } else if (isFloat){
            _outputFormat.mFormatFlags = kAudioFormatFlagIsFloat;
            _outputFormat.mFramesPerPacket = 1;
            _outputFormat.mBitsPerChannel = sizeof(float) * 8;
        }
        
        //packed only!
        _outputFormat.mFormatFlags |= kAudioFormatFlagIsPacked;
        _outputFormat.mBytesPerFrame = (_outputFormat.mBitsPerChannel / 8) * _outputFormat.mChannelsPerFrame;
        _outputFormat.mBytesPerPacket = _outputFormat.mBytesPerFrame * _outputFormat.mFramesPerPacket;
        
        OSStatus status = AudioQueueNewOutput(&self->_outputFormat, MRAudioQueueOutputCallback, (__bridge void *)self, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &self->_audioQueue);
        
        NSAssert(noErr == status, @"AudioQueueNewOutput");
        
        //初始化音频缓冲区--audioQueueBuffers为结构体数组
        for(int i = 0; i < QUEUE_BUFFER_SIZE;i++){
            int result = AudioQueueAllocateBuffer(self.audioQueue,MIN_SIZE_PER_FRAME, &self->audioQueueBuffers[i]);
            NSAssert(noErr == result, @"AudioQueueAllocateBuffer");
        }
        
        self.finalSampleFmt = fmt;
    }
}

#pragma mark - 音频

//音频渲染回调；
static void MRAudioQueueOutputCallback(
                                 void * __nullable       inUserData,
                                 AudioQueueRef           inAQ,
                                 AudioQueueBufferRef     inBuffer)
{
    MR0x21ViewController *am = (__bridge MR0x21ViewController *)inUserData;
    [am renderFramesToBuffer:inBuffer queue:inAQ];
}

- (UInt32)renderFramesToBuffer:(AudioQueueBufferRef) inBuffer queue:(AudioQueueRef)inAQ
{
    //1、填充数据
    UInt32 gotBytes = [self fetchPacketSample:inBuffer->mAudioData wantBytes:inBuffer->mAudioDataBytesCapacity];
    inBuffer->mAudioDataByteSize = gotBytes;
    
    // 2、通知 AudioQueue 有可以播放的 buffer 了
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    return gotBytes;
}

- (UInt32)fetchPacketSample:(uint8_t*)buffer
                  wantBytes:(UInt32)bufferSize
{
    UInt32 filled = [self.player fetchPacketSample:buffer wantBytes:bufferSize];
    
    #if DEBUG_RECORD_PCM_TO_FILE
    fwrite(buffer, 1, filled, file_pcm_l);
    #endif
    return filled;
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
