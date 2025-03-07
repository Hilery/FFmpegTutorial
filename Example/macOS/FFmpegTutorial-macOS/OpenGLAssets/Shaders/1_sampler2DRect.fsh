//  FFmpegTutorial
//
//  Created by qianlongxu.
//  Copyright © 2021 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.


// https://people.freedesktop.org/~marcheu/extensions/APPLE/ycbcr_422.html
//https://stackoverflow.com/questions/8788049/shader-differences-on-ios
//ERROR: 0:51: 'mat3' : declaration must include a precision qualifier for type
//precision mediump float;

uniform sampler2DRect SamplerY;
uniform vec2 textureDimensionY;

uniform mat3 colorConversionMatrix;
varying vec2 texCoordVarying;

void main()
{
    vec2 recTexCoordX = texCoordVarying * textureDimensionY;
    gl_FragColor = texture2DRect(SamplerY, recTexCoordX);
}
