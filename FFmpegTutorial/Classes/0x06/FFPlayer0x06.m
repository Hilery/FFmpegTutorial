//
//  FFPlayer0x06.m
//  FFmpegTutorial
//
//  Created by qianlongxu on 2020/5/21.
//

#import "FFPlayer0x06.h"
#import "MRThread.h"
#import "FFPlayerInternalHeader.h"
#import "FFPlayerPacketHeader.h"
#import "FFPlayerFrameHeader.h"
#import "FFDecoder0x06.h"
#include <libavutil/pixdesc.h>

@interface FFPlayer0x06 ()<FFDecoderDelegate0x06>
{
    //解码前的音频包缓存队列
    PacketQueue _audioq;
    //解码前的视频包缓存队列
    PacketQueue _videoq;
    
    //解码后的音频帧缓存队列
    FrameQueue _sampq;
    //解码后的视频帧缓存队列
    FrameQueue _pictq;
    
    //读包完毕？
    int _eof;
}

//读包线程
@property (nonatomic, strong) MRThread *readThread;
//渲染线程
@property (nonatomic, strong) MRThread *rendererThread;

//音频解码器
@property (nonatomic, strong) FFDecoder0x06 *audioDecoder;
//视频解码器
@property (nonatomic, strong) FFDecoder0x06 *videoDecoder;


@property (atomic, assign) int abort_request;
@property (nonatomic, copy) dispatch_block_t onErrorBlock;
@property (nonatomic, copy) dispatch_block_t onPacketBufferFullBlock;
@property (nonatomic, copy) dispatch_block_t onPacketBufferEmptyBlock;
@property (atomic, assign) BOOL packetBufferIsFull;
@property (atomic, assign) BOOL packetBufferIsEmpty;
@property (atomic, assign, readwrite) int videoFrameCount;
@property (atomic, assign, readwrite) int audioFrameCount;

@end

@implementation  FFPlayer0x06

static int decode_interrupt_cb(void *ctx)
{
    FFPlayer0x06 *player = (__bridge FFPlayer0x06 *)ctx;
    return player.abort_request;
}

- (void)_stop
{
    //避免重复stop做无用功
    if (self.readThread) {
        self.abort_request = 1;
        _audioq.abort_request = 1;
        _videoq.abort_request = 1;
        _sampq.abort_request = 1;
        _pictq.abort_request = 1;
        
        [self.readThread cancel];
        [self.audioDecoder cancel];
        [self.videoDecoder cancel];
        [self.rendererThread cancel];
        
        [self.readThread join];
        [self.audioDecoder join];
        [self.videoDecoder join];
        [self.rendererThread join];
    }
    [self performSelectorOnMainThread:@selector(didStop:) withObject:self waitUntilDone:YES];
}

- (void)didStop:(id)sender
{
    self.readThread = nil;
    self.audioDecoder = nil;
    self.videoDecoder = nil;
    self.rendererThread = nil;
    
    packet_queue_destroy(&_audioq);
    packet_queue_destroy(&_videoq);
    
    frame_queue_destory(&_pictq);
    frame_queue_destory(&_sampq);
}

- (void)dealloc
{
    PRINT_DEALLOC;
}

//准备
- (void)prepareToPlay
{
    if (self.readThread) {
        NSAssert(NO, @"不允许重复创建");
    }
    
    //初始化视频包队列
    packet_queue_init(&_videoq);
    //初始化音频包队列
    packet_queue_init(&_audioq);
    //初始化ffmpeg相关函数
    init_ffmpeg_once();
    
    //初始化视频帧队列
    frame_queue_init(&_pictq, VIDEO_PICTURE_QUEUE_SIZE, "pictq", 0);
    //初始化音频帧队列
    frame_queue_init(&_sampq, SAMPLE_QUEUE_SIZE, "sampq", 0);
    
    self.readThread = [[MRThread alloc] initWithTarget:self selector:@selector(readPacketsFunc) object:nil];
    self.readThread.name = @"mr-read";
}

#pragma mark - 打开解码器创建解码线程

- (FFDecoder0x06 *)openStreamComponent:(AVFormatContext *)ic streamIdx:(int)idx
{
    FFDecoder0x06 *decoder = [FFDecoder0x06 new];
    decoder.ic = ic;
    decoder.streamIdx = idx;
    if ([decoder open] == 0) {
        return decoder;
    } else {
        return nil;
    }
}

#pragma -mark 读包线程

//读包循环
- (void)readPacketLoop:(AVFormatContext *)formatCtx
{
    AVPacket pkt1, *pkt = &pkt1;
    //循环读包
    for (;;) {
        
        //调用了stop方法，则不再读包
        if (self.abort_request) {
            break;
        }
        
        /* 队列不满继续读，满了则休眠10 ms */
        if (_audioq.size + _videoq.size > MAX_QUEUE_SIZE
            || (stream_has_enough_packets(self.audioDecoder.stream, self.audioDecoder.streamIdx, &_audioq) &&
                stream_has_enough_packets(self.videoDecoder.stream, self.videoDecoder.streamIdx, &_videoq))) {
            
            if (!self.packetBufferIsFull) {
                self.packetBufferIsFull = YES;
                if (self.onPacketBufferFullBlock) {
                    self.onPacketBufferFullBlock();
                }
            }
            /* wait 10 ms */
            mr_msleep(10);
            continue;
        }
        
        self.packetBufferIsFull = NO;
        //读包
        int ret = av_read_frame(formatCtx, pkt);
        //读包出错
        if (ret < 0) {
            //读到最后结束了
            if ((ret == AVERROR_EOF || avio_feof(formatCtx->pb)) && !_eof) {
                //最后放一个空包进去
                if (self.audioDecoder.streamIdx >= 0) {
                    packet_queue_put_nullpacket(&_audioq, self.audioDecoder.streamIdx);
                }
                    
                if (self.videoDecoder.streamIdx >= 0) {
                    packet_queue_put_nullpacket(&_videoq, self.videoDecoder.streamIdx);
                }
                //标志为读包结束
                _eof = 1;
            }
            
            if (formatCtx->pb && formatCtx->pb->error) {
                break;
            }
            /* wait 10 ms */
            mr_msleep(10);
            continue;
        } else {
            //音频包入音频队列
            if (pkt->stream_index == self.audioDecoder.streamIdx) {
                packet_queue_put(&_audioq, pkt);
            }
            //视频包入视频队列
            else if (pkt->stream_index == self.videoDecoder.streamIdx) {
                packet_queue_put(&_videoq, pkt);
            }
            //其他包释放内存忽略掉
            else {
                av_packet_unref(pkt);
            }
        }
    }
}

#pragma mark - 查找最优的音视频流
- (void)findBestStreams:(AVFormatContext *)formatCtx result:(int (*) [AVMEDIA_TYPE_NB])st_index {

    int first_video_stream = -1;
    int first_h264_stream = -1;
    //查找H264格式的视频流
    for (int i = 0; i < formatCtx->nb_streams; i++) {
        AVStream *st = formatCtx->streams[i];
        enum AVMediaType type = st->codecpar->codec_type;
        st->discard = AVDISCARD_ALL;

        if (type == AVMEDIA_TYPE_VIDEO) {
            enum AVCodecID codec_id = st->codecpar->codec_id;
            if (codec_id == AV_CODEC_ID_H264) {
                if (first_h264_stream < 0) {
                    first_h264_stream = i;
                    break;
                }
                if (first_video_stream < 0) {
                    first_video_stream = i;
                }
            }
        }
    }
    //h264优先
    (*st_index)[AVMEDIA_TYPE_VIDEO] = first_h264_stream != -1 ? first_h264_stream : first_video_stream;
    //根据上一步确定的视频流查找最优的视频流
    (*st_index)[AVMEDIA_TYPE_VIDEO] = av_find_best_stream(formatCtx, AVMEDIA_TYPE_VIDEO, (*st_index)[AVMEDIA_TYPE_VIDEO], -1, NULL, 0);
    //参照视频流查找最优的音频流
    (*st_index)[AVMEDIA_TYPE_AUDIO] = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, (*st_index)[AVMEDIA_TYPE_AUDIO], (*st_index)[AVMEDIA_TYPE_VIDEO], NULL, 0);
}

- (void)readPacketsFunc
{
    if (![self.contentPath hasPrefix:@"/"]) {
        _init_net_work_once();
    }
    
    AVFormatContext *formatCtx = avformat_alloc_context();
    
    if (!formatCtx) {
        self.error = _make_nserror_desc(FFPlayerErrorCode_AllocFmtCtxFailed, @"创建 AVFormatContext 失败！");
        [self performErrorResultOnMainThread];
        return;
    }
    
    formatCtx->interrupt_callback.callback = decode_interrupt_cb;
    formatCtx->interrupt_callback.opaque = (__bridge void *)self;
    
    /*
     打开输入流，读取文件头信息，不会打开解码器；
     */
    //低版本是 av_open_input_file 方法
    const char *moviePath = [self.contentPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    //打开文件流，读取头信息；
    if (0 != avformat_open_input(&formatCtx, moviePath , NULL, NULL)) {
        //释放内存
        avformat_free_context(formatCtx);
        //当取消掉时，不给上层回调
        if (self.abort_request) {
            return;
        }
        self.error = _make_nserror_desc(FFPlayerErrorCode_OpenFileFailed, @"文件打开失败！");
        [self performErrorResultOnMainThread];
        return;
    }
    
    /* 刚才只是打开了文件，检测了下文件头而已，并不知道流信息；因此开始读包以获取流信息
     设置读包探测大小和最大时长，避免读太多的包！
    */
    formatCtx->probesize = 500 * 1024;
    formatCtx->max_analyze_duration = 5 * AV_TIME_BASE;
#if DEBUG
    NSTimeInterval begin = [[NSDate date] timeIntervalSinceReferenceDate];
#endif
    if (0 != avformat_find_stream_info(formatCtx, NULL)) {
        avformat_close_input(&formatCtx);
        self.error = _make_nserror_desc(FFPlayerErrorCode_StreamNotFound, @"不能找到流！");
        [self performErrorResultOnMainThread];
        //出错了，销毁下相关结构体
        avformat_close_input(&formatCtx);
        return;
    }
    
#if DEBUG
    NSTimeInterval end = [[NSDate date] timeIntervalSinceReferenceDate];
    //用于查看详细信息，调试的时候打出来看下很有必要
    av_dump_format(formatCtx, 0, moviePath, false);
    
    MRFF_DEBUG_LOG(@"avformat_find_stream_info coast time:%g",end-begin);
#endif
    
    //确定最优的音视频流
    int st_index[AVMEDIA_TYPE_NB];
    memset(st_index, -1, sizeof(st_index));
    [self findBestStreams:formatCtx result:&st_index];
    
    //打开音频解码器，创建解码线程
    if (st_index[AVMEDIA_TYPE_AUDIO] >= 0){
        
        self.audioDecoder = [self openStreamComponent:formatCtx streamIdx:st_index[AVMEDIA_TYPE_AUDIO]];
        
        if(self.audioDecoder){
            self.audioDecoder.delegate = self;
            self.audioDecoder.name = @"mr-audio-dec";
        } else {
            av_log(NULL, AV_LOG_ERROR, "can't open audio stream.");
            self.error = _make_nserror_desc(FFPlayerErrorCode_StreamOpenFailed, @"音频流打开失败！");
            [self performErrorResultOnMainThread];
            //出错了，销毁下相关结构体
            avformat_close_input(&formatCtx);
            return;
        }
    }

    //打开视频解码器，创建解码线程
    if (st_index[AVMEDIA_TYPE_VIDEO] >= 0){
        self.videoDecoder = [self openStreamComponent:formatCtx streamIdx:st_index[AVMEDIA_TYPE_VIDEO]];
        if(self.videoDecoder){
            self.videoDecoder.delegate = self;
            self.videoDecoder.name = @"mr-video-dec";
        } else {
            av_log(NULL, AV_LOG_ERROR, "can't open video stream.");
            self.error = _make_nserror_desc(FFPlayerErrorCode_StreamOpenFailed, @"视频流打开失败！");
            [self performErrorResultOnMainThread];
            //出错了，销毁下相关结构体
            avformat_close_input(&formatCtx);
            return;
        }
    }
    
    //音视频解码线程开始工作
    [self.audioDecoder start];
    [self.videoDecoder start];
    //准备渲染线程
    [self prepareRendererThread];
    //渲染线程开始工作
    [self.rendererThread start];
    //循环读包
    [self readPacketLoop:formatCtx];
    //读包线程结束了，销毁下相关结构体
    avformat_close_input(&formatCtx);
}

#pragma mark - FFDecoderDelegate0x06

- (int)decoder:(FFDecoder0x06 *)decoder wantAPacket:(AVPacket *)pkt
{
    if (decoder == self.audioDecoder) {
        return packet_queue_get(&_audioq, pkt, 1);
    } else if (decoder == self.videoDecoder) {
        return packet_queue_get(&_videoq, pkt, 1);
    } else {
        return -1;
    }
}

- (void)decoder:(FFDecoder0x06 *)decoder reveivedAFrame:(AVFrame *)frame
{
    FrameQueue *fq = NULL;
    if (decoder == self.audioDecoder) {
        fq = &_sampq;
        self.audioFrameCount++;
    } else if (decoder == self.videoDecoder) {
        fq = &_pictq;
        self.videoFrameCount++;
    }
    
    if (fq != NULL) {
        frame_queue_push(fq, frame, 0.0);
    }
}

#pragma mark - RendererThread

- (void)prepareRendererThread
{
    self.rendererThread = [[MRThread alloc] initWithTarget:self selector:@selector(rendererThreadFunc) object:nil];
    self.rendererThread.name = @"mr-renderer";
}

- (void)rendererThreadFunc
{
    //调用了stop方法，则不再渲染
    while (!self.abort_request) {
        
        //队列里缓存帧大于0，则取出
        if (frame_queue_nb_remaining(&_sampq) > 0) {
            Frame *ap = frame_queue_peek(&_sampq);
            av_log(NULL, AV_LOG_VERBOSE, "render audio frame %lld\n", ap->frame->pts);
            //释放该节点存储的frame的内存
            frame_queue_pop(&_sampq);
            self.audioFrameCount--;
        }
        
        if (frame_queue_nb_remaining(&_pictq) > 0) {
            Frame *vp = frame_queue_peek(&_pictq);
            av_log(NULL, AV_LOG_VERBOSE, "render video frame %lld\n", vp->frame->pts);
            frame_queue_pop(&_pictq);
            self.videoFrameCount--;
        }
        
        mr_msleep(40);
    }
}

- (void)performErrorResultOnMainThread
{
    MR_sync_main_queue(^{
        if (self.onErrorBlock) {
            self.onErrorBlock();
        }
    });
}

- (void)play
{
    [self.readThread start];
}

- (void)asyncStop
{
    [self performSelectorInBackground:@selector(_stop) withObject:self];
}

- (void)onError:(dispatch_block_t)block
{
    self.onErrorBlock = block;
}

- (void)onPacketBufferFull:(dispatch_block_t)block
{
    self.onPacketBufferFullBlock = block;
}

- (void)onPacketBufferEmpty:(dispatch_block_t)block
{
    self.onPacketBufferEmptyBlock = block;
}

- (MR_PACKET_SIZE)peekPacketBufferStatus
{
    return (MR_PACKET_SIZE){_videoq.nb_packets,_audioq.nb_packets,0};
}

@end
