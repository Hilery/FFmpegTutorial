//
//  FFDecoder0x10.h
//  FFmpegTutorial
//
//  Created by Matt Reach on 2020/6/2.
//
// 自定义解码器类
// 通过代理衔接输入输出

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct AVStream AVStream;
typedef struct AVFormatContext AVFormatContext;
typedef struct AVPacket AVPacket;
typedef struct AVFrame AVFrame;

@class FFDecoder0x10;
@protocol FFDecoderDelegate0x10 <NSObject>

@required
///解码器向 delegater 要一个 AVPacket
- (int)decoder:(FFDecoder0x10 *)decoder wantAPacket:(AVPacket *)packet;
///将解码后的 AVFrame 给 delegater
- (void)decoder:(FFDecoder0x10 *)decoder reveivedAFrame:(AVFrame *)frame;

@end

@interface FFDecoder0x10 : NSObject

@property (nonatomic, assign) AVFormatContext *ic;
@property (nonatomic, assign) int streamIdx;
@property (nonatomic, copy) NSString * name;
@property (nonatomic, weak) id <FFDecoderDelegate0x10> delegate;
@property (nonatomic, assign, readonly) AVStream * stream;
//for video
@property (nonatomic, assign, readonly) enum AVPixelFormat pix_fmt;
@property (nonatomic, assign, readonly) int picWidth;
@property (nonatomic, assign, readonly) int picHeight;
///记录解码后的视频桢总数
@property (atomic, assign, readonly) int videoFrameCount;
///记录解码后的音频桢总数
@property (atomic, assign, readonly) int audioFrameCount;

/**
 打开解码器，创建解码线程;
 return 0;（没有错误）
 */
- (int)open;
//开始解码
- (void)start;
//取消解码
- (void)cancel;
//内部线程join
- (void)join;

@end


NS_ASSUME_NONNULL_END
