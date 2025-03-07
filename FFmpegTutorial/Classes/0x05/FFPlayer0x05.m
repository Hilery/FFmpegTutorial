//
//  FFPlayer0x05.m
//  FFmpegTutorial
//
//  Created by qianlongxu on 2020/5/14.
//

#import "FFPlayer0x05.h"
#import "MRThread.h"
#import "FFPlayerInternalHeader.h"
#import "FFPlayerPacketHeader.h"
#import "FFPlayerFrameHeader.h"

#include <libavutil/pixdesc.h>


@interface  FFPlayer0x05 ()
{
    //解码前的音频包缓存队列
    PacketQueue _audioq;
    //解码前的视频包缓存队列
    PacketQueue _videoq;
    
    //音频流索引
    int _audio_stream;
    //视频流索引
    int _video_stream;
    
    //音频流解码器上下文
    AVCodecContext *_audioCodecCtx;
    //视频流解码器上下文
    AVCodecContext *_videoCodecCtx;
    
    //解码后的音频帧缓存队列
    FrameQueue _sampq;
    //解码后的视频帧缓存队列
    FrameQueue _pictq;
    
    //读包完毕？
    int _eof;
}

//读包线程
@property (nonatomic, strong) MRThread *readThread;

//视频解码线程
@property (nonatomic, strong) MRThread *videoDecodeThread;

//音频解码线程
@property (nonatomic, strong) MRThread *audioDecodeThread;

//渲染线程
@property (nonatomic, strong) MRThread *rendererThread;

@property (atomic, assign) int abort_request;
@property (nonatomic, copy) dispatch_block_t onErrorBlock;
@property (nonatomic, copy) dispatch_block_t onPacketBufferFullBlock;
@property (nonatomic, copy) dispatch_block_t onPacketBufferEmptyBlock;
@property (atomic, assign) BOOL packetBufferIsFull;
@property (atomic, assign) BOOL packetBufferIsEmpty;
@property (atomic, assign, readwrite) int videoFrameCount;
@property (atomic, assign, readwrite) int audioFrameCount;

@end

@implementation  FFPlayer0x05

static int decode_interrupt_cb(void *ctx)
{
    FFPlayer0x05 *player = (__bridge FFPlayer0x05 *)ctx;
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
        [self.audioDecodeThread cancel];
        [self.videoDecodeThread cancel];
        [self.rendererThread cancel];
        
        [self.readThread join];
        [self.audioDecodeThread join];
        [self.videoDecodeThread join];
        [self.rendererThread join];
    }
    [self performSelectorOnMainThread:@selector(didStop:) withObject:self waitUntilDone:YES];
}

- (void)didStop:(id)sender
{
    self.readThread = nil;
    self.audioDecodeThread = nil;
    self.videoDecodeThread = nil;
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
    _video_stream = _audio_stream = -1;
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

- (int)openStreamComponent:(AVFormatContext *)ic streamIdx:(int)idx
{
    if (ic == NULL) {
        return -1;
    }
    
    if (idx < 0 || idx >= ic->nb_streams){
        return -1;
    }
    
    AVStream *stream = ic->streams[idx];
    
    //创建解码器上下文
    AVCodecContext *avctx = avcodec_alloc_context3(NULL);
    if (!avctx) {
        return AVERROR(ENOMEM);
    }
    
    //填充下相关参数
    if (avcodec_parameters_to_context(avctx, stream->codecpar)) {
        avcodec_free_context(&avctx);
        return -1;
    }
    
    av_codec_set_pkt_timebase(avctx, stream->time_base);
    
    //查找解码器
    AVCodec *codec = avcodec_find_decoder(avctx->codec_id);
    if (!codec){
        avcodec_free_context(&avctx);
        return -1;
    }
    
    avctx->codec_id = codec->id;
    
    //打开解码器
    if (avcodec_open2(avctx, codec, NULL)) {
        avcodec_free_context(&avctx);
        return -1;
    }
    
    stream->discard = AVDISCARD_DEFAULT;
    
    //根据流类型，准备相关线程
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
        {
            _audio_stream = idx;
            _audioCodecCtx = avctx;
            //创建音频解码线程
            [self prepareAudioDecodeThread];
        }
            break;
        case AVMEDIA_TYPE_VIDEO:
        {
            _video_stream = stream->index;
            _videoCodecCtx = avctx;
            //创建视频解码线程
            [self prepareVideoDecodeThread];
        }
            break;
        default:
            break;
    }
    return 0;
}

#pragma -mark 读包线程

//读包循环
- (void)readPacketLoop:(AVFormatContext *)formatCtx
{
    AVPacket pkt1, *pkt = &pkt1;
    const AVStream *audio_st = formatCtx->streams[_audio_stream];
    const AVStream *video_st = formatCtx->streams[_video_stream];
    //循环读包
    for (;;) {
        
        //调用了stop方法，则不再读包
        if (self.abort_request) {
            break;
        }
        
        /* 队列不满继续读，满了则休眠10 ms */
        if (_audioq.size + _videoq.size > MAX_QUEUE_SIZE
            || (stream_has_enough_packets(audio_st, _audio_stream, &_audioq) &&
                stream_has_enough_packets(video_st, _video_stream, &_videoq))) {
            
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
                if (_video_stream >= 0) {
                    packet_queue_put_nullpacket(&_videoq, _video_stream);
                }
                    
                if (_audio_stream >= 0) {
                    packet_queue_put_nullpacket(&_audioq, _audio_stream);
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
            if (pkt->stream_index == _audio_stream) {
                packet_queue_put(&_audioq, pkt);
            }
            //视频包入视频队列
            else if (pkt->stream_index == _video_stream) {
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
    NSParameterAssert(self.contentPath);
        
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
    
    //打开解码器，创建解码线程
    if (st_index[AVMEDIA_TYPE_AUDIO] >= 0){
        if([self openStreamComponent:formatCtx streamIdx:st_index[AVMEDIA_TYPE_AUDIO]]){
            av_log(NULL, AV_LOG_ERROR, "can't open audio stream.");
            self.error = _make_nserror_desc(FFPlayerErrorCode_StreamOpenFailed, @"音频流打开失败！");
            [self performErrorResultOnMainThread];
            //出错了，销毁下相关结构体
            avformat_close_input(&formatCtx);
            return;
        }
    }
    
    if (st_index[AVMEDIA_TYPE_VIDEO] >= 0){
        if([self openStreamComponent:formatCtx streamIdx:st_index[AVMEDIA_TYPE_VIDEO]]){
            av_log(NULL, AV_LOG_ERROR, "can't open video stream.");
            self.error = _make_nserror_desc(FFPlayerErrorCode_StreamOpenFailed, @"视频流打开失败！");
            [self performErrorResultOnMainThread];
            //出错了，销毁下相关结构体
            avformat_close_input(&formatCtx);
            return;
        }
    }
    
    //音视频解码线程开始工作
    [self.audioDecodeThread start];
    [self.videoDecodeThread start];
    //准备渲染线程
    [self prepareRendererThread];
    //渲染线程开始工作
    [self.rendererThread start];
    //循环读包
    [self readPacketLoop:formatCtx];
    //读包线程结束了，销毁下相关结构体
    avformat_close_input(&formatCtx);
}

#pragma mark - 音视频通用解码方法

- (int)decoder_decode_frame:(AVCodecContext *)avctx queue:(PacketQueue *)queue frame:(AVFrame*)frame
{    
    for (;;) {
        int ret;
        do {
            //停止时，直接返回
            if (self.abort_request){
                return -1;
            }
            
            //先尝试接收帧
            ret = avcodec_receive_frame(avctx, frame);
            
            //成功接收到一个解码帧
            if (ret >= 0){
                return 1;
            }
            
            //结束标志，此次并没有获取到frame！
            if (ret == AVERROR_EOF) {
                avcodec_flush_buffers(avctx);
                return AVERROR_EOF;
            }
            
        } while (ret != AVERROR(EAGAIN)/*需要更多packet数据*/);
        
        AVPacket pkt;
        //[阻塞等待]直到获取一个packet
        int r = packet_queue_get(queue, &pkt, 1);
       
        if (r < 0)
        {
            return -1;
        }
        
        //发送给解码器去解码
        if (avcodec_send_packet(avctx, &pkt) == AVERROR(EAGAIN)) {
            av_log(avctx, AV_LOG_ERROR, "Receive_frame and send_packet both returned EAGAIN, which is an API violation.\n");
        }
        //释放内存
        av_packet_unref(&pkt);
    }
}

#pragma mark - AudioDecodeThread

- (void)prepareAudioDecodeThread
{
    self.audioDecodeThread = [[MRThread alloc] initWithTarget:self selector:@selector(audioDecodeFunc) object:nil];
    self.audioDecodeThread.name = @"mr-audio-dec";
}

#pragma mark - 音频解码线程

- (void)audioDecodeFunc
{
    //创建一个frame就行了，可以复用
    AVFrame *frame = av_frame_alloc();
    if (!frame) {
        av_log(NULL, AV_LOG_ERROR, "audioDecoder can't alloc a frame.\n");
        return;
    }
    do {
        //使用通用方法解码音频队列
        int got_frame = [self decoder_decode_frame:_audioCodecCtx queue:&_audioq frame:frame];
        //解码出错
        if (got_frame < 0) {
            if (got_frame == AVERROR_EOF) {
                av_log(NULL, AV_LOG_ERROR, "audioDecoder eof.\n");
            } else if (self.abort_request){
                av_log(NULL, AV_LOG_ERROR, "audioDecoder cancel.\n");
            } else {
                av_log(NULL, AV_LOG_ERROR, "audioDecoder decode err %d.\n",got_frame);
            }
            break;
        } else {
            //正常解码
            av_log(NULL, AV_LOG_VERBOSE, "decode a audio frame:%lld\n",frame->pts);
            self.audioFrameCount++;
            if (0 != frame_queue_push(&_sampq, frame, 0.0)) {
                break;
            }
        }
    } while (1);
    
    //释放内存
    if (frame) {
        av_frame_free(&frame);
    }
    
    //释放解码器上下文
    if (_audioCodecCtx) {
        avcodec_free_context(&_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
}

#pragma mark - VideoDecodeThread

- (void)prepareVideoDecodeThread
{
    self.videoDecodeThread = [[MRThread alloc] initWithTarget:self selector:@selector(videoDecodeFunc) object:nil];
    self.videoDecodeThread.name = @"mr-video-dec";;
}

#pragma mark - 视频解码线程

- (void)videoDecodeFunc
{
    //创建一个frame就行了，可以复用
    AVFrame *frame = av_frame_alloc();
    if (!frame) {
        av_log(NULL, AV_LOG_ERROR, "videoDecoder can't alloc a frame.\n");
        return;
    }
    do {
        //使用通用方法解码音频队列
        int got_frame = [self decoder_decode_frame:_videoCodecCtx queue:&_videoq frame:frame];
        //解码出错
        if (got_frame < 0) {
            if (got_frame == AVERROR_EOF) {
                av_log(NULL, AV_LOG_ERROR, "videoDecoder eof.\n");
            } else if (self.abort_request){
                av_log(NULL, AV_LOG_ERROR, "videoDecoder cancel.\n");
            } else {
                av_log(NULL, AV_LOG_ERROR, "videoDecoder decode err %d.\n",got_frame);
            }
            break;
        } else {
            //正常解码
            av_log(NULL, AV_LOG_VERBOSE, "decode a video frame:%lld\n",frame->pts);
            self.videoFrameCount++;
            if (0 != frame_queue_push(&_pictq, frame, 0.0)) {
                break;
            }
        }
    } while (1);
    
    //释放内存
    if (frame) {
        av_frame_free(&frame);
    }
    
    //释放解码器上下文
    if (_videoCodecCtx) {
        avcodec_free_context(&_videoCodecCtx);
        _videoCodecCtx = NULL;
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
    //调用了stop方法，则不再读包
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
        
        mr_msleep(arc4random() % 30 + 30);
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
