//
//  MR0x141OpenGLCompiler.m
//  FFmpegTutorial-macOS
//
//  Created by qianlongxu on 2021/7/24.
//  Copyright © 2021 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "MR0x141OpenGLCompiler.h"
#import <OpenGL/gl.h>
#import "renderer_pixfmt.h"

@interface MR0x141OpenGLCompiler ()

@property uint32_t program;

@end

@implementation MR0x141OpenGLCompiler

- (instancetype)initWithvshName:(NSString *)vshName
                        fshName:(NSString *)fshName
{
    self = [super init];
    if (self) {
        self.vshName = vshName;
        self.fshName = fshName;
    }
    return self;
}

- (BOOL)compileIfNeed
{
    if (self.program) {
        return YES;
    } else if (self.vshName.length > 0 && self.fshName.length > 0) {
        GLuint program = [self compileProgram];
        if (program > 0) {
            self.program = program;
            return YES;
        } else {
            return NO;
        }
    } else {
        return NO;
    }
}

- (void)active
{
    if (self.program > 0) {
        glUseProgram(self.program);
    }
}

- (int)getUniformLocation:(const char *)name
{
    NSAssert(self.program > 0, @"you must compile opengl program firstly!");
    NSAssert(strlen(name) > 0, @"what's your uniform name?");
    
    return glGetUniformLocation(self.program, name);
}

- (int)getAttribLocation:(const char *)name
{
    NSAssert(self.program > 0, @"you must compile opengl program firstly!");
    NSAssert(strlen(name) > 0, @"what's your uniform name?");
    
    return glGetAttribLocation(self.program, name);
}

- (GLuint)compileProgram
{
    debug_opengl_string("Version", GL_VERSION);
    debug_opengl_string("Vendor", GL_VENDOR);
    debug_opengl_string("Renderer", GL_RENDERER);
    debug_opengl_string("Extensions", GL_EXTENSIONS);
    
    // Create and compile the vertex shader.
    GLuint vertShader = [self compileShader:self.vshName type:GL_VERTEX_SHADER];
    
    // Create and compile fragment shader.
    GLuint fragShader = [self compileShader:self.fshName type:GL_FRAGMENT_SHADER];
    
    GLuint program = glCreateProgram();
    
    // Attach vertex shader to program.
    glAttachShader(program, vertShader);
    
    // Attach fragment shader to program.
    glAttachShader(program, fragShader);
    
    // Bind attribute locations. This needs to be done prior to linking.
    //glBindAttribLocation(self.program, ATTRIB_VERTEX, "position");
    //glBindAttribLocation(self.program, ATTRIB_TEXCOORD, "texCoord");
    
    // Link the program.
    if (![self linkProgram:program]) {
        if (vertShader) {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader) {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (self.program) {
            glDeleteProgram(self.program);
            self.program = 0;
        }
        NSAssert(NO, @"Failed link program:%d",program);
        return 0;
    }

    // Release vertex and fragment shaders.
    if (vertShader) {
        glDetachShader(program, vertShader);
        glDeleteShader(vertShader);
    }
    
    if (fragShader) {
        glDetachShader(program, fragShader);
        glDeleteShader(fragShader);
    }
    
    return program;
}

- (GLuint)compileShader:(NSString *)bundleFileName type:(GLenum)type
{
    NSURL *shaderURL = [[NSBundle mainBundle] URLForResource:[bundleFileName stringByDeletingPathExtension] withExtension:[bundleFileName pathExtension]];
    
    NSError *error;
    NSString *sourceString = [[NSString alloc] initWithContentsOfURL:shaderURL encoding:NSUTF8StringEncoding error:&error];
    
    if (sourceString == nil) {
        NSAssert(NO,@"load %@ failed for %@",bundleFileName,[error localizedDescription]);
        return 0;
    }
    
    GLint status;
    const GLchar *source = (GLchar *)[sourceString UTF8String];
    
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    
#if defined(DEBUG)
    GLint logLength;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        glDeleteShader(shader);
        NSAssert(NO, @"Failed to compile vertex shader");
        return 0;
    }
    
    return shader;
}

- (BOOL)linkProgram:(GLuint)prog
{
    GLint status;
    glLinkProgram(prog);
    
#if defined(DEBUG)
    GLint logLength;
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }
#endif
    
    glGetProgramiv(prog, GL_LINK_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

- (BOOL)validateProgram:(GLuint)prog
{
    GLint logLength, status;
    
    glValidateProgram(prog);
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program validate log:\n%s", log);
        free(log);
    }
    
    glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

@end
