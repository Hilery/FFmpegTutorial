//
//  MR0x201VideoRenderer.h
//  FFmpegTutorial-macOS
//
//  Created by qianlongxu on 2021/9/21.
//  Copyright © 2021 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <CoreVideo/CVPixelBuffer.h>
#import "MRVideoRendererProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface MR0x201VideoRenderer : NSOpenGLView<MRVideoRendererProtocol>

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;

@end

NS_ASSUME_NONNULL_END
