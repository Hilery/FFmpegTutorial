//
//  mr_play.c
//  MRMoviePlayer
//
//  Created by qianlongxu on 2020/1/31.
//

#include "mr_play.h"
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>
#include <stdbool.h>
#include <assert.h>
#include <sys/time.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
#include <libavutil/frame.h>

#define MIN_PKT_DURATION 15
#define MAX_QUEUE_SIZE (50 * 1024 * 1024) ///需要考虑该如何分配packet queue大小问题，
#define MAX_PACKET_COUNT 500
#define FRAME_QUEUE_SIZE 16
#define REFRESH_RATE 0.01
#define AV_SYNC_THRESHOLD_MIN 0.04
/* AV sync correction is done if above the maximum AV sync threshold */
#define AV_SYNC_THRESHOLD_MAX 0.1
/* If a frame duration is longer than this, it will not be duplicated to compensate AV sync */
#define AV_SYNC_FRAMEDUP_THRESHOLD 0.1
/* no AV correction is done if too big error */
#define AV_NOSYNC_THRESHOLD 10.0


static void mrlog(const char * f, ...){
    va_list args;       //定义一个va_list类型的变量，用来储存单个参数
    va_start(args,f); //使args指向可变参数的第一个参数
    vprintf(f,args);  //必须用vprintf等带V的
    va_end(args);       //结束可变参数的获取
}

#define DEBUG_LOG_ON 1

#if DEBUG_LOG_ON
#define DEBUGLog(...) do { \
    mrlog(__VA_ARGS__);  \
} while (0)
#else
#define DEBUGLog(...) do { } while (0)
#endif

#define INFO(...) do { \
    mrlog(__VA_ARGS__);  \
} while (0)

typedef struct Clock {
    double pts;           /* clock base */
    double pts_drift;     /* clock base minus time at which we updated the clock */
    double last_updated;
    double speed;
    int serial;           /* clock is based on a packet with this serial */
    int paused;
    int *queue_serial;    /* pointer to the current packet queue serial, used for obsolete clock detection */

} Clock;

static void set_clock_at(Clock *c, double pts, int serial, double time)
{
    c->pts = pts;
    c->last_updated = time;
    c->pts_drift = c->pts - time;
    c->serial = serial;
}

static void set_clock(Clock *c, double pts, int serial)
{
    double time = av_gettime_relative() / 1000000.0;
    set_clock_at(c, pts, serial, time);
}

static void init_clock(Clock *c, int *queue_serial)
{
    c->speed = 1.0;
    c->paused = 0;
    c->queue_serial = queue_serial;
    set_clock(c, NAN, -1);
}

typedef struct MRAVPacketNode {
    AVPacket pkt;
    struct MRAVPacketNode *next;
    int serial;
} MRAVPacketNode;

typedef struct PacketQueue {
    const char *name;
    MRAVPacketNode *first_pkt, *last_pkt;
    int nb_packets;
    int size;
    int64_t duration;
    int abort_request;
    int serial;
    MRAVPacketNode *recycle_pkt;
    int recycle_count;
    int alloc_count;
    int is_buffer_indicator;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} PacketQueue;

static int packet_queue_init(PacketQueue *q, const char *name)
{
    memset(q, 0, sizeof(PacketQueue));
    
    if (pthread_cond_init(&q->cond,NULL) != 0){
        av_log(NULL, AV_LOG_FATAL, "pthread_cond_init cond failed.\n");
        return AVERROR(ENOMEM);;
    }
    
    if (pthread_mutex_init(&q->mutex, NULL)) {
        av_log(NULL, AV_LOG_FATAL, "pthread_mutex_init failed.\n");
        return AVERROR(ENOMEM);
    }
    
    q->name = av_strdup(name);
    return 0;
}

static int packet_queue_put_private(PacketQueue *q, AVPacket *pkt){
    
    if (q->abort_request){
        return -1;
    }
    
    MRAVPacketNode *node = q->recycle_pkt;
    if (node) {
        q->recycle_pkt = node->next;
        q->recycle_count++;
    } else {
        q->alloc_count++;
        node = av_malloc(sizeof(MRAVPacketNode));
    }
    
    if (!node) {
        return -1;
    }
    
    node->pkt = *pkt;
    node->next = NULL;
    node->serial = q->serial;
    
    if (!q->last_pkt) {
        q->first_pkt = node;
    } else {
        q->last_pkt->next = node;
    }
    q->last_pkt = node;
    q->nb_packets++;
    q->size += node->pkt.size + sizeof(*node);
    q->duration += FFMAX(node->pkt.duration, MIN_PKT_DURATION);
    DEBUGLog("packet queue put %s (%d/%d)\n", q->name, node->serial, q->nb_packets);
    pthread_cond_signal(&q->cond);
    return 0;
}

static int packet_queue_put(PacketQueue *q, AVPacket *pkt){
    int ret;
    pthread_mutex_lock(&q->mutex);
    ret = packet_queue_put_private(q, pkt);
    pthread_mutex_unlock(&q->mutex);
    if (ret < 0) {
        av_packet_unref(pkt);
    }
    return ret;
}

static int packet_queue_put_nullpacket(PacketQueue *q, int stream_index){
    AVPacket pkt1, *pkt = &pkt1;
    av_init_packet(pkt);
    pkt->data = NULL;
    pkt->size = 0;
    pkt->stream_index = stream_index;
    return packet_queue_put(q, pkt);
}

/* return < 0 if aborted, 0 if no packet and > 0 if packet.  */
static int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block, int *serial)
{
    MRAVPacketNode *node;
    int ret;

    pthread_mutex_lock(&q->mutex);

    for (;;) {
        if (q->abort_request) {
            ret = -1;
            break;
        }

        node = q->first_pkt;
        if (node) {
            q->first_pkt = node->next;
            if (!q->first_pkt)
                q->last_pkt = NULL;
            q->nb_packets--;
            q->size -= node->pkt.size + sizeof(*node);
            q->duration -= FFMAX(node->pkt.duration, MIN_PKT_DURATION);
            *pkt = node->pkt;
            if (serial){
                *serial = node->serial;
            }
        
            node->next = q->recycle_pkt;
            q->recycle_pkt = node;
            ret = 1;
            
            DEBUGLog("packet queue get %s (%d/%d)\n", q->name, node->serial,q->nb_packets);
            break;
        } else if (!block) {
            ret = 0;
            break;
        } else {
            pthread_cond_wait(&q->cond, &q->mutex);
        }
    }
    pthread_mutex_unlock(&q->mutex);
    return ret;
}

static int packet_queue_get_or_buffering(PacketQueue *q, AVPacket *pkt, int *serial, int *finished)
{
    assert(finished);
    
    while (1) {
        int new_packet = packet_queue_get(q, pkt, 0, serial);
        if (new_packet < 0){
            return -1;
        } else if (new_packet == 0) {
            DEBUGLog("buffering packet.\n");
            new_packet = packet_queue_get(q, pkt, 1, serial);
            if (new_packet < 0){
                return -1;
            }
        }
        
        break;
//        if (*finished == *serial) {
//            av_packet_unref(pkt);
//            continue;
//        }
//        else
//            break;
    }

    return 1;
}

typedef struct Decoder {
    PacketQueue *queue;
    AVCodecContext *avctx;
    const char *name;
    
    int pkt_serial;
    int finished;
    pthread_t decode_t;
    pthread_cond_t empty_queue_cond;
    
    //音频重采样上下文
    SwrContext  *swr_ctx;
    enum AVSampleFormat target_sample_format;
    
    //视频格式转换
    int pic_width,pic_height;
    enum AVPixelFormat target_pixel_format;
    struct SwsContext *sws_ctx;
    float time_base;
    float fps;
}Decoder;

typedef struct Frame {
    AVFrame *frame;
    int serial;
    double pts;           /* presentation timestamp for the frame */
    double duration;      /* estimated duration of the frame */
    int64_t pos;          /* byte position of the frame in the input file */

    int width;
    int height;
    int format;
    
    int left_offset;
    int right_offset;
} Frame;

typedef struct FrameQueue {
    Frame queue[FRAME_QUEUE_SIZE];
    int rindex;
    int windex;
    int size;
    int max_size;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    PacketQueue *pktq;
    char *name;
    int serial;
} FrameQueue;

static int frame_queue_init(FrameQueue *f, PacketQueue *pktq, int max_size, int keep_last, const char *name)
{
    int i;
    memset(f, 0, sizeof(FrameQueue));
    f->name = av_strdup(name);
    if (pthread_mutex_init(&f->mutex, NULL)) {
        av_log(NULL, AV_LOG_FATAL, "pthread_mutex_init failed.\n");
        return AVERROR(ENOMEM);
    }
    
    if (pthread_cond_init(&f->cond, NULL)) {
        av_log(NULL, AV_LOG_FATAL, "pthread_cond_init failed.\n");
        return AVERROR(ENOMEM);
    }
    
    f->pktq = pktq;
    f->max_size = FFMIN(max_size, FRAME_QUEUE_SIZE);
    
    for (i = 0; i < f->max_size; i++)
        if (!(f->queue[i].frame = av_frame_alloc()))
            return AVERROR(ENOMEM);
    return 0;
}

static Frame *frame_queue_peek_writable(FrameQueue *f)
{
    /* wait until we have space to put a new frame */
    pthread_mutex_lock(&f->mutex);
    while (f->size >= f->max_size &&
           !f->pktq->abort_request) {
        DEBUGLog("%s frame queue is full(%d)\n",f->name,f->size);
        pthread_cond_wait(&f->cond, &f->mutex);
    }
    pthread_mutex_unlock(&f->mutex);

    if (f->pktq->abort_request)
        return NULL;
    
    Frame *af = &f->queue[f->windex];
    ///important! reset to zero.
    af->left_offset = 0;
    af->right_offset = 0;
    return af;
}

static void frame_queue_push(FrameQueue *f)
{
    pthread_mutex_lock(&f->mutex);
    
    DEBUGLog("frame queue put %s (%d/%d)\n", f->name, f->windex, f->size + 1);
    
    if (++f->windex == f->max_size){
        f->windex = 0;
    }
    
    f->size++;
    pthread_cond_signal(&f->cond);
    pthread_mutex_unlock(&f->mutex);
}

static void frame_queue_unref_item(Frame *vp)
{
    av_frame_unref(vp->frame);
}

static void frame_queue_next(FrameQueue *f)
{
    pthread_mutex_lock(&f->mutex);
    frame_queue_unref_item(&f->queue[f->rindex]);
    
    DEBUGLog("frame queue get %s (%d/%d)\n", f->name, f->rindex, f->size-1);
    
    if (++f->rindex == f->max_size){
        f->rindex = 0;
    }
    f->size--;
    pthread_cond_signal(&f->cond);
    pthread_mutex_unlock(&f->mutex);
}

static Frame *frame_queue_peek_readable(FrameQueue *f, int block)
{
    /* wait until we have a readable a new frame */
    pthread_mutex_lock(&f->mutex);
    while (f->size <= 0 && !f->pktq->abort_request) {
        DEBUGLog("%s frame queue is empty\n",f->name);
        if (block) {
            pthread_cond_wait(&f->cond, &f->mutex);
        } else {
            pthread_mutex_unlock(&f->mutex);
            return NULL;
        }
    }
    pthread_mutex_unlock(&f->mutex);

    if (f->pktq->abort_request)
        return NULL;
    Frame *frame = &f->queue[f->rindex];
    DEBUGLog("frame queue read %d %s (%d/%d)\n",frame->serial ,f->name, f->rindex,f->size);
    return frame;
}

/* return the number of undisplayed frames in the queue */
static int frame_queue_nb_remaining(FrameQueue *f)
{
    return f->size;
}

static Frame *frame_queue_peek_last(FrameQueue *f)
{
    return &f->queue[f->rindex];
}

static Frame *frame_queue_peek_next(FrameQueue *f)
{
    return &f->queue[(f->rindex + 1) % f->max_size];
}

static Frame *frame_queue_peek(FrameQueue *f)
{
    return &f->queue[(f->rindex) % f->max_size];
}

enum {
    AV_SYNC_AUDIO_MASTER, /* default choice */
    AV_SYNC_VIDEO_MASTER,
    AV_SYNC_EXTERNAL_CLOCK, /* synchronize to an external clock */
};

typedef struct VideoState {
    
    const char *url;
    MsgFunc msg_func;
    void *msg_func_ctx;
    
    int supported_sample_fmts;
    int supported_sample_rate;
    
    int supported_pixel_fmts;
    DisplayFunc display_func;
    void *display_func_ctx;
    AVFrame *dispalying;
    
    pthread_t read_t,video_refresh_t;
    pthread_cond_t read_thread_cond;
    
    AVFormatContext *ic;
    
    int audio_stream;
    int video_stream;
    
    AVStream *audio_st;
    AVStream *video_st;
    
    Decoder auddec;
    Decoder viddec;
    
    PacketQueue audioq;
    PacketQueue videoq;
    
    FrameQueue sampq;
    FrameQueue pictq;
    
    int av_sync_type;
    Clock vidclk;
    Clock audclk;
    Clock extclk;
    double frame_timer;
    double max_frame_duration;
    bool paused;
}VideoState;

static void msg_post (VideoState *is, MR_Msg_Type type);
static void msg_post_arg1 (VideoState *is, MR_Msg_Type type, int arg1);
static void msg_post_arg2 (VideoState *is, MR_Msg_Type type, int arg1, int arg2);

#pragma mark -
#pragma mark - Utils

static MRSampleFormat AVSampleFormat2MR (enum AVSampleFormat avsf){
    switch (avsf) {
        case AV_SAMPLE_FMT_S16P:
            return MR_SAMPLE_FMT_S16P;
        case AV_SAMPLE_FMT_S16:
            return MR_SAMPLE_FMT_S16;
        case AV_SAMPLE_FMT_FLTP:
            return MR_SAMPLE_FMT_FLTP;
        case AV_SAMPLE_FMT_FLT:
            return MR_SAMPLE_FMT_FLT;
        default:
        {
            assert(0);
            return MR_SAMPLE_FMT_NONE;
        }
            break;
    }
}

static enum AVSampleFormat MRSampleFormat2AV (MRSampleFormat mrsf){
    switch (mrsf) {
        case MR_SAMPLE_FMT_S16P:
            return AV_SAMPLE_FMT_S16P;
        case MR_SAMPLE_FMT_S16:
            return AV_SAMPLE_FMT_S16;
        case MR_SAMPLE_FMT_FLTP:
            return AV_SAMPLE_FMT_FLTP;
        case MR_SAMPLE_FMT_FLT:
            return AV_SAMPLE_FMT_FLT;
        default:
        {
            assert(0);
            return AV_SAMPLE_FMT_NONE;
        }
            break;
    }
}

static MRPixelFormat AVPixelFormat2MR (enum AVPixelFormat avpf){
    switch (avpf) {
        case AV_PIX_FMT_YUV420P:
            return MR_PIX_FMT_YUV420P;
        case AV_PIX_FMT_NV12:
            return MR_PIX_FMT_NV12;
        case AV_PIX_FMT_NV21:
            return MR_PIX_FMT_NV21;
        case AV_PIX_FMT_RGB24:
            return MR_PIX_FMT_RGB24;
        default:
        {
            assert(0);
            return MR_PIX_FMT_NONE;
        }
            break;
    }
}

static enum AVPixelFormat MRPixelFormat2AV (MRPixelFormat mrpf){
    switch (mrpf) {
        case MR_PIX_FMT_YUV420P:
            return AV_PIX_FMT_YUV420P;
        case MR_PIX_FMT_NV12:
            return AV_PIX_FMT_NV12;
        case MR_PIX_FMT_NV21:
            return AV_PIX_FMT_NV21;
        case MR_PIX_FMT_RGB24:
            return AV_PIX_FMT_RGB24;
        default:
        {
            assert(0);
            return AV_PIX_FMT_NONE;
        }
            break;
    }
}

#pragma mark -
#pragma mark - 音频重采样

static int create_swr_ctx_ifneed(VideoState *is,Decoder *decoder){
    
    enum AVSampleFormat format = decoder->avctx->sample_fmt;
    if (is->supported_sample_fmts == 0) {
        return 1;
    }
    
    bool matched = false;
    
    if ((is->supported_sample_fmts & MR_SAMPLE_FMT_FLT) && (format == MRSampleFormat2AV(MR_SAMPLE_FMT_FLT))) {
        matched = true;
    }
    
    if (!matched) {
        if ((is->supported_sample_fmts & MR_SAMPLE_FMT_FLTP) && (format == MRSampleFormat2AV(MR_SAMPLE_FMT_FLTP))) {
            matched = true;
        }
    }
    
    if (!matched) {
        if ((is->supported_sample_fmts & MR_SAMPLE_FMT_S16) && (format == MRSampleFormat2AV(MR_SAMPLE_FMT_S16))) {
            matched = true;
        }
    }
    
    if (!matched) {
        if ((is->supported_sample_fmts & MR_SAMPLE_FMT_S16P) && (format == MRSampleFormat2AV(MR_SAMPLE_FMT_S16P))) {
            matched = true;
        }
    }
    
    if (!matched) {
        enum AVSampleFormat first_supported_format = AV_SAMPLE_FMT_NONE;
        
        if ((is->supported_sample_fmts & MR_SAMPLE_FMT_FLT)) {
            first_supported_format = MRSampleFormat2AV(MR_SAMPLE_FMT_FLT);
        }
        
        if (AV_SAMPLE_FMT_NONE == first_supported_format) {
            if ((is->supported_sample_fmts & MR_SAMPLE_FMT_FLTP)) {
                first_supported_format = MRSampleFormat2AV(MR_SAMPLE_FMT_FLTP);
            }
        }
        
        if (AV_SAMPLE_FMT_NONE == first_supported_format) {
            if ((is->supported_sample_fmts & MR_SAMPLE_FMT_S16)) {
                first_supported_format = MRSampleFormat2AV(MR_SAMPLE_FMT_S16);
            }
        }
        
        if (AV_SAMPLE_FMT_NONE == first_supported_format) {
            if ((is->supported_sample_fmts & MR_SAMPLE_FMT_S16P)) {
                first_supported_format = MRSampleFormat2AV(MR_SAMPLE_FMT_S16P);
            }
        }
        
        if (AV_SAMPLE_FMT_NONE == first_supported_format) {
            return -1;
        }
        
        decoder->target_sample_format = first_supported_format;
    } else {
        decoder->target_sample_format = format;
    }
    
    ///当前音频格式与设备支持格式匹配，则需要判断采样率是否一致
    if (matched) {
        matched = decoder->avctx->sample_rate == is->supported_sample_rate;
    }
    
    ///不匹配，则需要创建重采样上下文
    if (!matched) {
        
        int64_t src_ch_layout = av_get_default_channel_layout(decoder->avctx->channels);
        int64_t dst_ch_layout = src_ch_layout;//av_get_default_channel_layout(2);
        
        enum AVSampleFormat src_sample_fmt = decoder->avctx->sample_fmt;
        enum AVSampleFormat dst_sample_fmt = decoder->target_sample_format;
        
        int src_rate = decoder->avctx->sample_rate;
        int dst_rate = is->supported_sample_rate;
        
        /* create resampler context */
//        SwrContext *swr_ctx = swr_alloc();
//
//        /* set options */
//        av_opt_set_int(swr_ctx, "in_channel_layout",    src_ch_layout, 0);
//        av_opt_set_int(swr_ctx, "in_sample_rate",       src_rate, 0);
//        av_opt_set_sample_fmt(swr_ctx, "in_sample_fmt", src_sample_fmt, 0);
//
//        av_opt_set_int(swr_ctx, "out_channel_layout",    dst_ch_layout, 0);
//        av_opt_set_int(swr_ctx, "out_sample_rate",       dst_rate, 0);
//        av_opt_set_sample_fmt(swr_ctx, "out_sample_fmt", dst_sample_fmt, 0);
        
        SwrContext *swr_ctx = swr_alloc_set_opts(NULL,
                                                 dst_ch_layout,dst_sample_fmt,dst_rate,
                                                 src_ch_layout,src_sample_fmt,src_rate,
                                                 0,
                                                 NULL);
        
        int ret = swr_init(swr_ctx);
        if (ret) {
            swr_free(&swr_ctx);
            return ret;
        } else {
            decoder->swr_ctx = swr_ctx;
        }
    }
    return 0;
}

static int resample_audio_frame(AVFrame *in, AVFrame **out, VideoState *is){
    
    int dst_rate = is->supported_sample_rate;
    
    Decoder d = is->auddec;
    enum AVSampleFormat dst_sample_fmt = d.target_sample_format;
    
    //int64_t dst_ch_layout;
    //av_opt_get_int(d.swr_ctx, "out_channel_layout", 0, &dst_ch_layout);
    
    AVFrame *out_frame = av_frame_alloc();
    ///important！
    av_frame_copy_props(out_frame, in);
    
    out_frame->channel_layout = in->channel_layout;
    out_frame->sample_rate = dst_rate;
    out_frame->format = dst_sample_fmt;
    
    int ret = swr_convert_frame(d.swr_ctx, out_frame, in);
    if(ret < 0){
        // convert error, try next frame
        av_log(NULL, AV_LOG_ERROR, "fail resample audio");
        av_frame_free(&out_frame);
        return -1;
    }
    
    *out = out_frame;
    
    return 0;
}

#pragma mark -
#pragma mark - 视频像素格式转换

static int create_sws_ctx_ifneed(VideoState *is,Decoder *decoder){
    
    if (is->supported_pixel_fmts == 0) {
        return 1;
    }
    
    enum AVPixelFormat format = decoder->avctx->pix_fmt;
    
    bool matched = false;
    
    if ((is->supported_pixel_fmts & MR_PIX_FMT_YUV420P) && (format == MRPixelFormat2AV(MR_PIX_FMT_YUV420P))) {
        matched = true;
        return 0;
    }
    
    if (!matched) {
        if ((is->supported_pixel_fmts & MR_PIX_FMT_NV12) && (format == MRPixelFormat2AV(MR_PIX_FMT_NV12))) {
            matched = true;
            return 0;
        }
    }
    
    if (!matched) {
        if ((is->supported_pixel_fmts & MR_PIX_FMT_NV21) && (format == MRPixelFormat2AV(MR_PIX_FMT_NV21))) {
            matched = true;
            return 0;
        }
    }
    
    if (!matched) {
        if ((is->supported_pixel_fmts & MR_PIX_FMT_RGB24) && (format == MRPixelFormat2AV(MR_PIX_FMT_RGB24))) {
            matched = true;
            return 0;
        }
    }
    
    if (!matched) {
        enum AVPixelFormat first_supported_format = AV_PIX_FMT_NONE;
        
        if ((is->supported_pixel_fmts & MR_PIX_FMT_YUV420P)) {
            first_supported_format = MRPixelFormat2AV(MR_PIX_FMT_YUV420P);
        }
        
        if (AV_PIX_FMT_NONE == first_supported_format) {
            if ((is->supported_pixel_fmts & MR_PIX_FMT_NV12)) {
                first_supported_format = MRPixelFormat2AV(MR_PIX_FMT_NV12);
            }
        }
        
        if (AV_PIX_FMT_NONE == first_supported_format) {
            if ((is->supported_pixel_fmts & MR_PIX_FMT_NV21)) {
                first_supported_format = MRPixelFormat2AV(MR_PIX_FMT_NV21);
            }
        }
        
        if ((is->supported_pixel_fmts & MR_PIX_FMT_RGB24)) {
            first_supported_format = MRPixelFormat2AV(MR_PIX_FMT_RGB24);
        }
        
        if (AV_PIX_FMT_NONE == first_supported_format) {
            return -1;
        }
        
        decoder->target_pixel_format = first_supported_format;
    } else {
        decoder->target_pixel_format = format;
    }
    
    ///不匹配，则需要创建像素格式转换上下文
    if (!matched) {
        
        enum AVPixelFormat src_pix_fmt = decoder->avctx->pix_fmt;
        enum AVPixelFormat dst_pix_fmt = decoder->target_pixel_format;
        
        decoder->sws_ctx = sws_getContext(decoder->pic_width, decoder->pic_height, src_pix_fmt, decoder->pic_width, decoder->pic_height, dst_pix_fmt, SWS_POINT, NULL, NULL, NULL);
        
        if (NULL == decoder->sws_ctx) {
            return -1;
        }
    }
    return 0;
}

static int rescale_video_frame(AVFrame *in, AVFrame **out, VideoState *is){
    
    assert(out);
    
    Decoder d = is->viddec;
    
    AVFrame *out_frame = av_frame_alloc();
    ///important！
    av_frame_copy_props(out_frame, in);
    
    out_frame->format  = d.target_pixel_format;
    out_frame->width   = d.pic_width;
    out_frame->height  = d.pic_height;
    
    memcpy(out_frame->linesize, in->linesize, sizeof(out_frame->linesize));
    
    av_image_alloc(out_frame->data, out_frame->linesize, d.pic_width, d.pic_height, d.target_pixel_format, 1);
    
    int ret = sws_scale(d.sws_ctx, (const uint8_t* const*)in->data, in->linesize, 0, in->height, out_frame->data, out_frame->linesize);
    if(ret < 0){
        // convert error, try next frame
        av_log(NULL, AV_LOG_ERROR, "fail scale video");
        av_freep(&out_frame->data);
        av_frame_free(&out_frame);
        return -1;
    }
    
    *out = out_frame;
    return 0;
}

#pragma mark -
#pragma mark - 通用解码方法

static int decoder_decode_frame(Decoder *d, AVFrame *frame) {
    
    int ret = AVERROR(EAGAIN);

    for (;;) {
        do {
            if (d->queue->abort_request){
                return -1;
            }

            ret = avcodec_receive_frame(d->avctx, frame);
            
            if (ret >= 0){
                return 1;
            }
            
            if (ret == AVERROR_EOF) {
                d->finished = d->pkt_serial;
                avcodec_flush_buffers(d->avctx);
                return -1;
            }
            
        } while (ret != AVERROR(EAGAIN));

        if (d->queue->nb_packets == 0){
            pthread_cond_signal(&d->empty_queue_cond);
        }
        
        AVPacket pkt;
        
        if (packet_queue_get_or_buffering(d->queue, &pkt, &d->pkt_serial, &d->finished) < 0)
        {
            return -1;
        }
        
        if (avcodec_send_packet(d->avctx, &pkt) == AVERROR(EAGAIN)) {
            av_log(d->avctx, AV_LOG_ERROR, "Receive_frame and send_packet both returned EAGAIN, which is an API violation.\n");
        }
        
        av_packet_unref(&pkt);
    }
}

#pragma mark -
#pragma mark - 音频解码线程

static void * audio_decode_func (void *ptr){
    VideoState *is = ptr;
    AVFrame *frame = av_frame_alloc();
    if (!frame) {
        av_log(NULL, AV_LOG_ERROR, "can't alloc a frame.");
        return NULL;
    }
    do {
        int got_frame = decoder_decode_frame(&is->auddec, frame);
        
        if (got_frame < 0) {
            if (is->viddec.finished) {
                av_log(NULL, AV_LOG_ERROR, "decode frame eof.");
            } else {
                av_log(NULL, AV_LOG_ERROR, "can't decode frame.");
            }
            break;
        } else {
            AVFrame *out = frame;
            int resampled = 0;
            ///存在音频重采样器，则进行重采样
            if(is->auddec.swr_ctx) {
                if (resample_audio_frame(frame ,&out, is)) {
                    av_log(NULL, AV_LOG_ERROR, "can't resample audio frame.");
                    break;
                } else {
                    resampled = 1;
                }
            }
            
            Frame *af = NULL;
            if (NULL == (af = frame_queue_peek_writable(&is->sampq))) {
                break;
            }
            
            is->sampq.serial++;
            af->serial = is->sampq.serial;
            if (out->pts != AV_NOPTS_VALUE) {
                af->pts = is->auddec.time_base * out->pts;
            }
            
            av_frame_ref(af->frame, out);
            frame_queue_push(&is->sampq);
            
            if (resampled) {
                av_frame_free(&out);
            }
        }
    } while (1);
    
    if (frame) {
        av_frame_free(&frame);
    }
    
    return NULL;
}

#pragma mark -
#pragma mark - 视频解码线程

static void * video_decode_func (void *ptr){
    VideoState *is = ptr;
    AVFrame *frame = av_frame_alloc();
    if (!frame) {
        av_log(NULL, AV_LOG_ERROR, "can't alloc a frame.");
        return NULL;
    }
    
    do {
        
        int got_frame = decoder_decode_frame(&is->viddec, frame);
        
        if (got_frame < 0) {
            if (is->viddec.finished) {
                av_log(NULL, AV_LOG_ERROR, "decode frame eof.");
            } else {
                av_log(NULL, AV_LOG_ERROR, "can't decode frame.");
            }
            break;
        } else {
            AVFrame *out = frame;
            int scaled = 0;
            ///存在视频转换器，则进行格式转换
            if(is->viddec.sws_ctx){
                if (rescale_video_frame(frame, &out, is)) {
                    av_log(NULL, AV_LOG_ERROR, "can't rescale video frame.");
                    break;
                } else {
                    scaled = 1;
                }
            }
            
            Frame *af = NULL;
            if (NULL == (af = frame_queue_peek_writable(&is->pictq))){
                break;
            }
            
            if (out->pts != AV_NOPTS_VALUE) {
                af->pts = is->viddec.time_base * out->pts;
            }
            
            double duration = av_frame_get_pkt_duration(out);
            
            if ((int)(duration * 1000) == 0) {
                duration = 1 / is->viddec.fps;
            } else {
                duration = duration * is->viddec.time_base;
                duration += af->frame->repeat_pict / (2 * is->viddec.fps);
            }
            
            af->duration = duration;
            is->pictq.serial++;
            af->serial = is->pictq.serial;
            av_frame_ref(af->frame, out);
            frame_queue_push(&is->pictq);
            if (scaled) {
                av_freep(out->data);
                av_frame_free(&out);
            }
        }
    } while (1);
    
    if (frame) {
        av_frame_free(&frame);
    }
    
    return NULL;
}

#pragma mark -
#pragma mark - 通用方法

#pragma mark 解码结构初始化方法

static void avStreamTimeBase(AVRational st_time_base, AVRational codec_time_base, float defaultTimeBase, float *pTimeBase)
{
    float timebase;
    
    if (st_time_base.den && st_time_base.num)
        timebase = av_q2d(st_time_base);
    else if(codec_time_base.den && codec_time_base.num)
        timebase = av_q2d(codec_time_base);
    else
        timebase = defaultTimeBase;
    
    if (pTimeBase)
        *pTimeBase = timebase;
}

static void fpsForVideoStream(AVStream * st, float time_base, float *pFPS)
{
    if (AVMEDIA_TYPE_VIDEO != st->codecpar->codec_type) {
        assert(1);
    }
    
    float fps;
    
    if (st->avg_frame_rate.den && st->avg_frame_rate.num)
        fps = av_q2d(st->avg_frame_rate);
    else if (st->r_frame_rate.den && st->r_frame_rate.num)
        fps = av_q2d(st->r_frame_rate);
    else
        fps = 1.0 / time_base;

    if (pFPS)
        *pFPS = fps;
}


static void decoder_init(Decoder *d, PacketQueue *queue, AVCodecContext *avctx, const char *name){
    memset(d, 0, sizeof(Decoder));
    d->avctx = avctx;
    d->queue = queue;
    d->name  = av_strdup(name);
}

#pragma mark -
#pragma mark - 解码线程创建方法

static int decoder_start(Decoder *d, void * (*fn)(void *), void *arg)
{
    if (pthread_cond_init(&d->empty_queue_cond, NULL)) {
        av_log(NULL, AV_LOG_ERROR, "%s pthread_cond_init failed\n",d->name);
        return AVERROR(ENOMEM);
    }
    
    if (pthread_create(&d->decode_t, NULL, fn, arg)) {
        av_log(NULL, AV_LOG_ERROR, "%s ptherad create failed\n",d->name);
        return AVERROR(ENOMEM);
    }
    return 0;
}

#pragma mark -
#pragma mark - 打开流，然后开始起线程解码

static int stream_component_open(VideoState *is, int stream_index){
    
    AVFormatContext *ic = is->ic;
    
    if (ic == NULL) {
        return -1;
    }
    if (stream_index < 0 || stream_index >= ic->nb_streams){
        return -1;
    }
    AVStream *stream = ic->streams[stream_index];
    AVCodecContext *avctx = avcodec_alloc_context3(NULL);
    if (!avctx) {
        return AVERROR(ENOMEM);
    }
    
    if (avcodec_parameters_to_context(avctx, stream->codecpar)) {
        avcodec_free_context(&avctx);
        return -1;
    }
    
    av_codec_set_pkt_timebase(avctx, stream->time_base);
    
    AVCodec *codec = avcodec_find_decoder(avctx->codec_id);
    if (!codec){
        avcodec_free_context(&avctx);
        return -1;
    }
    
    avctx->codec_id = codec->id;
    
    if (avcodec_open2(avctx, codec, NULL)) {
        avcodec_free_context(&avctx);
        return -1;
    }
    
    stream->discard = AVDISCARD_DEFAULT;
    
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
        {
            is->audio_stream = stream_index;
            is->audio_st = stream;
            decoder_init(&is->auddec, &is->audioq, avctx, "audio_decode");
            
            avStreamTimeBase(stream->time_base, is->auddec.avctx->time_base, 0.025, &is->auddec.time_base);
            
            if (create_swr_ctx_ifneed(is, &is->auddec)) {
                avcodec_free_context(&avctx);
                av_log(NULL, AV_LOG_ERROR, "can't create_swr_ctx");
                return -1;
            }
            
            msg_post_arg1(is,MR_Msg_Type_InitAudioRender,AVSampleFormat2MR(is->auddec.target_sample_format));
            
            if (decoder_start(&is->auddec, audio_decode_func, (void *)is)) {
                avcodec_free_context(&avctx);
                av_log(NULL, AV_LOG_ERROR, "can't start decode auido\n");
                return -1;
            }
        }
            break;
        case AVMEDIA_TYPE_VIDEO:
        {
            is->video_stream = stream_index;
            is->video_st = stream;
            
            decoder_init(&is->viddec, &is->videoq, avctx, "video_decode");
            
            ///画面宽度，单位像素
            is->viddec.pic_width = avctx->width;
            ///画面高度，单位像素
            is->viddec.pic_height = avctx->height;
            
            avStreamTimeBase(stream->time_base, is->viddec.avctx->time_base, 0.04, &is->viddec.time_base);
            fpsForVideoStream(stream, is->viddec.time_base, &is->viddec.fps);
            
            if (create_sws_ctx_ifneed(is, &is->viddec)) {
                avcodec_free_context(&avctx);
                av_log(NULL, AV_LOG_ERROR, "can't create_sws_ctx.\n");
                return -1;
            }
            
            msg_post_arg2(is,MR_Msg_Type_InitVideoRender, is->viddec.pic_width, is->viddec.pic_height);
            
            if (decoder_start(&is->viddec, video_decode_func, (void *)is)) {
                avcodec_free_context(&avctx);
                av_log(NULL, AV_LOG_ERROR, "can't start decode video\n");
                return -1;
            }
        }
            break;
        default:
            break;
    }
    return 0;
}

static int stream_has_enough_packets(AVStream *st, int stream_id, PacketQueue *queue, int max_count) {
    return stream_id < 0 ||
           queue->abort_request ||
           queue->nb_packets >= max_count;
}

static int need_read_more_packet(VideoState *is){
    int full = (is->audioq.size + is->videoq.size > MAX_QUEUE_SIZE) ||
                stream_has_enough_packets(is->audio_st, is->audio_stream, &is->audioq, MAX_PACKET_COUNT) ||
                stream_has_enough_packets(is->video_st, is->video_stream, &is->videoq, MAX_PACKET_COUNT);
    return !full;
}

#pragma mark -
#pragma mark - 读包线程

static void *read_thread(void *ptr){
    VideoState *is = ptr;
    AVFormatContext *ic = NULL;
    AVDictionary *format_opts = NULL;
    av_dict_set(&format_opts, "safe", "0", 0);
    int ret = avformat_open_input(&ic, is->url, NULL, &format_opts);
    if (ret) {
        av_log(NULL, AV_LOG_FATAL, "Could not open input(%d).\n",ret);
        return NULL;
    }
    
    ///不调用这个方法，发现视频的 pix_fmt 未知
    ret = avformat_find_stream_info(ic, NULL);
    if (ret) {
        avformat_close_input(&ic);
        av_log(NULL, AV_LOG_FATAL, "Could not find steam info(%d).\n",ret);
        return NULL;
    }
     
    is->ic = ic;
    
    is->max_frame_duration = (ic->iformat->flags & AVFMT_TS_DISCONT) ? 10.0 : 3600.0;

    int st_index[AVMEDIA_TYPE_NB];
    memset(st_index, -1, sizeof(st_index));
    
    int first_video_stream = -1;
    int first_h264_stream = -1;
    
    for (int i = 0; i < ic->nb_streams; i++) {
        AVStream *st = ic->streams[i];
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
    
    if (st_index[AVMEDIA_TYPE_VIDEO] < 0) {
        st_index[AVMEDIA_TYPE_VIDEO] = first_h264_stream != -1 ? first_h264_stream : first_video_stream;
    }
    
    st_index[AVMEDIA_TYPE_VIDEO] = av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO, st_index[AVMEDIA_TYPE_VIDEO], -1, NULL, 0);
    
    st_index[AVMEDIA_TYPE_AUDIO] = av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO, st_index[AVMEDIA_TYPE_AUDIO], st_index[AVMEDIA_TYPE_VIDEO], NULL, 0);
    
    if (st_index[AVMEDIA_TYPE_AUDIO] >= 0){
        if(stream_component_open(is,st_index[AVMEDIA_TYPE_AUDIO])){
            av_log(NULL, AV_LOG_ERROR, "can't open audio stream.");
#warning todo clean
            return NULL;
        }
    }
    
    if (st_index[AVMEDIA_TYPE_VIDEO] >= 0){
        if(stream_component_open(is,st_index[AVMEDIA_TYPE_VIDEO])){
            av_log(NULL, AV_LOG_ERROR, "can't open video stream.");
#warning todo clean
            return NULL;
        }
    }
    
    AVPacket pkt1, *pkt = &pkt1;
    
    pthread_mutex_t wait_mutex;
    if (pthread_mutex_init(&wait_mutex, NULL)) {
        //todo clean
        av_log(NULL, AV_LOG_ERROR, "can't init wait_mutex.");
        return NULL;
    }
    
    for (;;) {
        
        while (need_read_more_packet(is)) {
            ret = av_read_frame(ic, pkt);
            if (ret < 0) {
                if (ret == AVERROR_EOF) {
                    if (is->video_stream >= 0)
                        packet_queue_put_nullpacket(&is->videoq, is->video_stream);
                    if (is->audio_stream >= 0)
                        packet_queue_put_nullpacket(&is->audioq, is->audio_stream);
                    break;
                }
            } else {
                if (pkt->stream_index == is->audio_stream) {
                    is->audioq.serial ++;
                    packet_queue_put(&is->audioq, pkt);
                } else if (pkt->stream_index == is->video_stream) {
                    is->videoq.serial ++;
                    packet_queue_put(&is->videoq, pkt);
                } else {
                    av_packet_unref(pkt);
                }
            }
        }
        
        if (ret == AVERROR_EOF){
            break;
        } else {
            DEBUGLog("packet buffer is full,wait 10ms.\n");
            
            unsigned int ms = 10;
            struct timeval delta;
            struct timespec abstime;

            gettimeofday(&delta, NULL);

            abstime.tv_sec = delta.tv_sec + (ms / 1000);
            abstime.tv_nsec = (delta.tv_usec + (ms % 1000) * 1000) * 1000;
            if (abstime.tv_nsec > 1000000000) {
                abstime.tv_sec += 1;
                abstime.tv_nsec -= 1000000000;
            }
            
            msg_post(is, MR_Msg_Type_PackQueueIsFull);
            pthread_mutex_lock(&wait_mutex);
            //pthread_cond_wait(&is->read_thread_cond, &wait_mutex);
            pthread_cond_timedwait(&is->read_thread_cond, &wait_mutex, &abstime);
            pthread_mutex_unlock(&wait_mutex);
        }
    }
    
    if (ic){
        avformat_close_input(&ic);
        is->ic = NULL;
    }
    
    pthread_mutex_destroy(&wait_mutex);
    INFO("read packet EOF\n");
    
    return NULL;
}

static double get_clock(Clock *c)
{
    if (*c->queue_serial != c->serial)
        return NAN;
    if (c->paused) {
        return c->pts;
    } else {
        double time = av_gettime_relative() / 1000000.0;
        return c->pts_drift + time - (time - c->last_updated) * (1.0 - c->speed);
    }
}

static int get_master_sync_type(VideoState *is) {
    if (is->av_sync_type == AV_SYNC_VIDEO_MASTER) {
        if (is->video_st)
            return AV_SYNC_VIDEO_MASTER;
        else
            return AV_SYNC_AUDIO_MASTER;
    } else if (is->av_sync_type == AV_SYNC_AUDIO_MASTER) {
        if (is->audio_st)
            return AV_SYNC_AUDIO_MASTER;
        else
            return AV_SYNC_EXTERNAL_CLOCK;
    } else {
        return AV_SYNC_EXTERNAL_CLOCK;
    }
}


/* get the current master clock value */
static double get_master_clock(VideoState *is)
{
    double val;

    switch (get_master_sync_type(is)) {
        case AV_SYNC_VIDEO_MASTER:
            val = get_clock(&is->vidclk);
            break;
        case AV_SYNC_AUDIO_MASTER:
            val = get_clock(&is->audclk);
            break;
        default:
            assert(0);
            //val = get_clock(&is->extclk);
            break;
    }
    return val;
}

static void sync_clock_to_slave(Clock *c, Clock *slave)
{
    double clock = get_clock(c);
    double slave_clock = get_clock(slave);
    if (!isnan(slave_clock) && (isnan(clock) || fabs(clock - slave_clock) > AV_NOSYNC_THRESHOLD))
        set_clock(c, slave_clock, slave->serial);
}

static void update_video_pts(VideoState *is, double pts, int64_t pos, int serial) {
    /* update current video pts */
    set_clock(&is->vidclk, pts, serial);
    sync_clock_to_slave(&is->extclk, &is->vidclk);
}


#pragma mark 提供 packet 音频数据

int mr_fetch_packet_sample(MRPlayer opaque, uint8_t *buffer, int want){
    assert(opaque);
    VideoState *is = opaque;
    
    assert(!av_sample_fmt_is_planar(is->auddec.target_sample_format));
    
    if (is->paused) {
        return 0;
    }
    
    DEBUGLog("want sample size:%d\n",want);
    
    while (want > 0) {
        Frame *af;
        if (!(af = frame_queue_peek_readable(&is->sampq, 0))){
            msg_post(is, MR_Msg_Type_FrameQueueIsEmpty);
            return 0;
        }
        
        if (af->left_offset == 0) {
//            is->clock.main_pts = af->pts;
            /* Let's assume the audio driver that is used by SDL has two periods. */
            double audio_clock = af->pts + (double) af->frame->nb_samples / af->frame->sample_rate;
            if (audio_clock) {
                set_clock_at(&is->audclk, audio_clock , 0, av_gettime_relative() / 1000000.0);
                sync_clock_to_slave(&is->extclk, &is->audclk);
            }
            DEBUGLog("audio frame pts:%.2f\n",af->pts);
        }
        uint8_t *src = af->frame->data[0];
        
        int data_size = av_samples_get_buffer_size(af->frame->linesize, 2, af->frame->nb_samples, is->auddec.target_sample_format, 1);
        int l_src_size = data_size;//af->frame->linesize[0];
        
        const void *from = src + af->left_offset;
        int left = l_src_size - af->left_offset;
        
        ///根据剩余数据长度和需要数据长度算出应当copy的长度
        int leftBytesToCopy = FFMIN(want, left);
        
        memcpy(buffer, from, leftBytesToCopy);
        buffer += leftBytesToCopy;
        want -= leftBytesToCopy;
        af->left_offset += leftBytesToCopy;
        
        DEBUGLog("fill sample size:%d\n",leftBytesToCopy);
        
        if (leftBytesToCopy >= left){
            //读取完毕，则清空；读取下一个包
            DEBUGLog("packet sample:next frame\n");
            frame_queue_next(&is->sampq);
        }
    }
    return 0;
}

#pragma mark 提供 palnar 音频数据

int mr_fetch_planar_sample(MRPlayer opaque, uint8_t *l_buffer, int l_size, uint8_t *r_buffer, int r_size){
    assert(opaque);
    
    VideoState *is = opaque;
    
    assert(av_sample_fmt_is_planar(is->auddec.target_sample_format));
    
    if (is->paused) {
        return 0;
    }
    
    DEBUGLog("want planar sample size:%d\n",l_size);
    
    while (l_size > 0 || r_size > 0) {
        Frame *af;
        if (!(af = frame_queue_peek_readable(&is->sampq, 0))){
            msg_post(is, MR_Msg_Type_FrameQueueIsEmpty);
            return 0;
        }
        
        if (af->left_offset == 0) {
            DEBUGLog("audio frame pts:%.2f\n",af->pts);
//            is->clock.main_pts = af->pts;
            /* Let's assume the audio driver that is used by SDL has two periods. */
            double audio_clock = af->pts + (double) af->frame->nb_samples / af->frame->sample_rate;
            if (audio_clock) {
                set_clock_at(&is->audclk, audio_clock , 0, av_gettime_relative() / 1000000.0);
                sync_clock_to_slave(&is->extclk, &is->audclk);
            }
        }
        
        uint8_t *l_src = af->frame->data[0];
        
        int data_size = av_samples_get_buffer_size(af->frame->linesize, 1, af->frame->nb_samples, is->auddec.target_sample_format, 1);
        int l_src_size = data_size;//af->frame->linesize[0];
        
        const void *leftFrom = l_src + af->left_offset;
        int leftBytesLeft = l_src_size - af->left_offset;
        
        ///根据剩余数据长度和需要数据长度算出应当copy的长度
        int leftBytesToCopy = FFMIN(l_size, leftBytesLeft);
        
        memcpy(l_buffer, leftFrom, leftBytesToCopy);
        l_buffer += leftBytesToCopy;
        l_size -= leftBytesToCopy;
        af->left_offset += leftBytesToCopy;
        DEBUGLog("fill planar sample size:%d\n",leftBytesToCopy);
        uint8_t *r_src = af->frame->data[1];
        int r_src_size = l_src_size;//af->frame->linesize[1];
        if (r_src) {
            const void *right_from = r_src + af->right_offset;
            int right_bytes_left = r_src_size - af->right_offset;
            
            ///根据剩余数据长度和需要数据长度算出应当copy的长度
            int rightBytesToCopy = FFMIN(r_size, right_bytes_left);
            memcpy(r_buffer, right_from, rightBytesToCopy);
            r_buffer += rightBytesToCopy;
            r_size -= rightBytesToCopy;
            af->right_offset += rightBytesToCopy;
        }
        
        if (leftBytesToCopy >= leftBytesLeft){
            //读取完毕，则清空；读取下一个包
            DEBUGLog("planar sample:next frame\n");
            frame_queue_next(&is->sampq);
        }
    }
    
    return 0;
}

static double vp_duration(VideoState *is, Frame *vp, Frame *nextvp) {
    if (vp->serial == nextvp->serial) {
        double duration = nextvp->pts - vp->pts;
        if (isnan(duration) || duration <= 0 || duration > is->max_frame_duration)
            return vp->duration;
        else
            return duration;
    } else {
        return 0.0;
    }
}


// 根据视频时钟与同步时钟(如音频时钟)的差值，校正delay值，使视频时钟追赶或等待同步时钟
// 输入参数delay是上一帧播放时长，即上一帧播放后应延时多长时间后再播放当前帧，通过调节此值来调节当前帧播放快慢
// 返回值delay是将输入参数delay经校正后得到的值
static double compute_target_delay(double delay, VideoState *is)
{
    double sync_threshold, diff = 0;

    /* if video is slave, we try to correct big delays by
       duplicating or deleting a frame */
    // 视频时钟与同步时钟(如音频时钟)的差异，时钟值是上一帧pts值(实为：上一帧pts + 上一帧至今流逝的时间差)
    diff = get_clock(&is->vidclk) - get_master_clock(is);
    // delay是上一帧播放时长：当前帧(待播放的帧)播放时间与上一帧播放时间差理论值
    // diff是视频时钟与同步时钟的差值

    /* skip or repeat frame. We take into account the
       delay to compute the threshold. I still don't know
       if it is the best guess */
    // 若delay < AV_SYNC_THRESHOLD_MIN，则同步域值为AV_SYNC_THRESHOLD_MIN
    // 若delay > AV_SYNC_THRESHOLD_MAX，则同步域值为AV_SYNC_THRESHOLD_MAX
    // 若AV_SYNC_THRESHOLD_MIN < delay < AV_SYNC_THRESHOLD_MAX，则同步域值为delay
    sync_threshold = FFMAX(AV_SYNC_THRESHOLD_MIN, FFMIN(AV_SYNC_THRESHOLD_MAX, delay));
    if (!isnan(diff) && fabs(diff) < is->max_frame_duration) {
        if (diff <= -sync_threshold)        // 视频时钟落后于同步时钟，且超过同步域值
            delay = FFMAX(0, delay + diff); // 当前帧播放时刻落后于同步时钟(delay+diff<0)则delay=0(视频追赶，立即播放)，否则delay=delay+diff
        else if (diff >= sync_threshold && delay > AV_SYNC_FRAMEDUP_THRESHOLD)  // 视频时钟超前于同步时钟，且超过同步域值，但上一帧播放时长超长
            delay = delay + diff;           // 仅仅校正为delay=delay+diff，主要是AV_SYNC_FRAMEDUP_THRESHOLD参数的作用，不作同步补偿
        else if (diff >= sync_threshold)    // 视频时钟超前于同步时钟，且超过同步域值
            delay = 2 * delay;              // 视频播放要放慢脚步，delay扩大至2倍
    }

    av_log(NULL, AV_LOG_TRACE, "video: delay=%0.3f A-V=%f\n",
            delay, -diff);

    return delay;
}

static void video_display(VideoState *is)
{
    Frame *af;
    if (!(af = frame_queue_peek_readable(&is->pictq, 0))){
        msg_post(is, MR_Msg_Type_FrameQueueIsEmpty);
        return;
    }

    //    DEBUGLog("video frame pts:%.2f\n",af->pts);
    //    DEBUGLog("display frame:%g\n",duration);

    //release old pic
    av_frame_unref(is->dispalying);
    // retain new pic.
    av_frame_ref(is->dispalying, af->frame);
    if (is->display_func) {
        is->display_func(is->display_func_ctx,is->dispalying);
    }
}

static void video_refresh(VideoState *is,double *remaining_time)
{
    double time;
    int force_refresh;
retry:
    ///没有桢可显示
    if (frame_queue_nb_remaining(&is->pictq) == 0) {
        // nothing to do, no picture to display in the queue
        force_refresh = 0;
    } else {
        double last_duration, duration, delay;
        Frame *vp, *lastvp;
        // 上一帧：上次已显示的帧
        lastvp = frame_queue_peek_last(&is->pictq);
        // 当前帧：当前待显示的帧
        vp = frame_queue_peek(&is->pictq);
        
//        if (vp->serial != is->videoq.serial) {
//            frame_queue_next(&is->pictq);
//            goto retry;
//        }
        // lastvp和vp不是同一播放序列(一个seek会开始一个新播放序列)，将frame_timer更新为当前时间
        if (lastvp->serial != vp->serial)
            is->frame_timer = av_gettime_relative() / 1000000.0;

        // 暂停处理：不停播放上一帧图像
        if (is->paused)
            goto display;

        /* compute nominal last_duration */
        last_duration = vp_duration(is, lastvp, vp);        // 上一帧播放时长：vp->pts - lastvp->pts
        delay = compute_target_delay(last_duration, is);    // 根据视频时钟和同步时钟的差值，计算delay值

        time= av_gettime_relative()/1000000.0;
        // 当前帧播放时刻(is->frame_timer+delay)大于当前时刻(time)，表示播放时刻未到
        if (time < is->frame_timer + delay) {
            // 播放时刻未到，则更新刷新时间remaining_time为当前时刻到下一播放时刻的时间差
            *remaining_time = FFMIN(is->frame_timer + delay - time, *remaining_time);
            // 播放时刻未到，则不更新rindex，把上一帧再lastvp再播放一遍
            goto display;
        }

        // 更新frame_timer值
        is->frame_timer += delay;
        // 校正frame_timer值：若frame_timer落后于当前系统时间太久(超过最大同步域值)，则更新为当前系统时间
        if (delay > 0 && time - is->frame_timer > AV_SYNC_THRESHOLD_MAX)
            is->frame_timer = time;
        
        pthread_mutex_lock(&is->pictq.mutex);
        if (!isnan(vp->pts))
            update_video_pts(is, vp->pts, vp->pos, vp->serial); // 更新视频时钟：时间戳、时钟时间
        pthread_mutex_unlock(&is->pictq.mutex);

        // 是否要丢弃未能及时播放的视频帧
        if (frame_queue_nb_remaining(&is->pictq) > 1) {         // 队列中未显示帧数>1(只有一帧则不考虑丢帧)
            Frame *nextvp = frame_queue_peek_next(&is->pictq);  // 下一帧：下一待显示的帧
            duration = vp_duration(is, vp, nextvp);             // 当前帧vp播放时长 = nextvp->pts - vp->pts
            // 丢帧策略: 当前帧vp未能及时播放，即下一帧播放时刻(is->frame_timer+duration)小于当前系统时刻(time)
            if(time > is->frame_timer + duration){
                // framedrop丢帧处理有两处：1) packet入队列前，2) frame未及时显示(此处)
                frame_queue_next(&is->pictq);   // 删除上一帧已显示帧，即删除lastvp，读指针加1(从lastvp更新到vp)
                goto retry;
            }
        }

        // 删除当前读指针元素，读指针+1。若未丢帧，读指针从lastvp更新到vp；若有丢帧，读指针从vp更新到nextvp
        frame_queue_next(&is->pictq);
        force_refresh = 1;
    }
display:
    /* display picture */
    if (force_refresh)
        video_display(is);                      // 取出当前帧vp(若有丢帧是nextvp)进行播放
}

#pragma mark -
#pragma mark - 视频刷新线程

static void *video_refresh_thread(void *ptr){
    VideoState *is = ptr;
    double remaining_time = 0.0;
    while (1) {
        if (remaining_time > 0.0)
            av_usleep((int)(int64_t)(remaining_time * 1000000.0));
        remaining_time = REFRESH_RATE;
        if (is->paused) {
            continue;
        }
        video_refresh(is, &remaining_time);
    }
    return NULL;
}

#pragma mark -
#pragma mark - FFMpeg 全局初始化方法

static void ff_global_init(){
    static bool flag = false;
    
    if (!flag) {
        
        av_register_all();
        avformat_network_init();
//        av_log_set_level(AV_LOG_DEBUG);
        flag = true;
    }
}

#pragma mark -
#pragma mark - 创建播放器

void * mr_player_instance_create(mr_init_params* params){
    VideoState *is = av_mallocz(sizeof(VideoState));
    if (!is) {
        return NULL;
    }
    is->url = av_strdup(params->url);
    is->msg_func = params->msg_func;
    is->msg_func_ctx = params->msg_func_ctx;
    
    is->supported_sample_fmts = params->supported_sample_fmts;
    is->supported_sample_rate = params->supported_sample_rate;
    
    is->supported_pixel_fmts = params->supported_pixel_fmts;
    is->av_sync_type = AV_SYNC_AUDIO_MASTER;
    ff_global_init();
    
    return is;
}

#pragma mark -
#pragma mark - 准备播放，开始加载资源

int mr_prepare_play(MRPlayer opaque){
    
    assert(opaque);
    VideoState *is = opaque;
    
    is->dispalying = av_frame_alloc();
    
    if (frame_queue_init(&is->sampq, &is->audioq, 9, 1, "audio") || frame_queue_init(&is->pictq, &is->videoq, 3, 1, "video")){
        av_freep(is);
        return -1;
    }
    
    if (packet_queue_init(&is->audioq, "audio") || packet_queue_init(&is->videoq, "video")) {
        av_freep(is);
#warning need destroy queue!
        return -1;
    }

    init_clock(&is->vidclk, &is->videoq.serial);
    init_clock(&is->audclk, &is->audioq.serial);
    init_clock(&is->extclk, &is->extclk.serial);

    if (pthread_cond_init(&is->read_thread_cond,NULL) != 0){
        INFO("pthread_cond_init read_thread_cond error\n");
        return -1;
    }
    
    if (pthread_create(&is->read_t,NULL,read_thread,is)) {
        av_free((void *)is->url);
        av_freep(is);
        return -1;
    }
    
    if (pthread_create(&is->video_refresh_t,NULL,video_refresh_thread,is)) {
        av_free((void *)is->url);
        av_freep(is);
        return -1;
    }
    
    return 0;
}

int mr_play(MRPlayer opaque){
    assert(opaque);
    INFO("mr_play\n");
    VideoState *is = opaque;
    is->paused = is->audclk.paused = is->vidclk.paused = is->extclk.paused = !is->paused;
    return 0;
}

int mr_pause(MRPlayer opaque){
    assert(opaque);
    INFO("mr_pause\n");
    VideoState *is = opaque;
    is->paused = is->audclk.paused = is->vidclk.paused = is->extclk.paused = !is->paused;
    return 0;
}

#pragma mark -
#pragma mark - 设置视频渲染回调方法

int mr_set_display_func(MRPlayer opaque, void *context, DisplayFunc func) {
    assert(opaque);
    VideoState *is = opaque;
#warning need lock here!
    is->display_func = func;
    is->display_func_ctx = context;
    return 0;
}

static void msg_post_arg2 (VideoState *is, MR_Msg_Type type, int arg1, int arg2){
    if (is->msg_func) {
        size_t size = sizeof(MR_Msg);
        MR_Msg *msg = malloc(size);
        bzero(msg, size);
        msg->type = type;
        msg->arg1 = arg1;
        msg->arg2 = arg2;
        is->msg_func(is->msg_func_ctx,msg);
        free(msg);
        msg = NULL;
    }
}

static void msg_post_arg1 (VideoState *is, MR_Msg_Type type, int arg1){
    msg_post_arg2(is, type, arg1, 0);
}

static void msg_post (VideoState *is, MR_Msg_Type type){
    msg_post_arg1(is, type, 0);
}
