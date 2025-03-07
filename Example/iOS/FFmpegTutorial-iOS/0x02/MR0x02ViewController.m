//
//  MR0x02ViewController.m
//  FFmpegTutorial-iOS
//
//  Created by qianlongxu on 2020/4/25.
//  Copyright © 2020 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "MR0x02ViewController.h"
#import <FFmpegTutorial/FFPlayer0x02.h>

@interface MR0x02ViewController ()

@property (nonatomic, strong) FFPlayer0x02 *player;
@property (weak, nonatomic) IBOutlet UITextView *textView;
@property (weak, nonatomic) IBOutlet UIActivityIndicatorView *indicatorView;

@end

@implementation MR0x02ViewController

- (void)dealloc
{
    if (self.player) {
        [self.player asyncStop];
        self.player = nil;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    [self.indicatorView startAnimating];
    FFPlayer0x02 *player = [[FFPlayer0x02 alloc] init];
    player.contentPath = KTestVideoURL1;
    [player prepareToPlay];
    __weakSelf__
    [player openStream:^(NSError * _Nullable error, NSString * _Nullable info) {
        __strongSelf__
        [self.indicatorView stopAnimating];
        if (error) {
            self.textView.text = [error localizedDescription];
        } else {
            self.textView.text = info;
        }
        [self.player asyncStop];
        self.player = nil;
    }];
    
    self.player = player;
}

@end
