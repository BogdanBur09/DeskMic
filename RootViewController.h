#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface RootViewController : UIViewController <UITextFieldDelegate> {
@public
    int _socketFd;
    struct sockaddr_in _destAddr;
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioBuffers[3];
    BOOL _isStreaming;
    uint64_t _packetsSent;
    uint64_t _bytesSent;

    // DSP State Variables
    float _hpPrevIn;
    float _hpPrevOut;
    float _gateGain;
    int _gateHoldCounter;

    // Feature Toggles
    BOOL _dualMicEnabled;
    BOOL _lowCutEnabled;
    BOOL _declickerEnabled;
    BOOL _noiseGateEnabled;
    BOOL _peakLimiterEnabled;
    float _hwGainValue;
}

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;

@property (nonatomic, strong) UITextField *ipTextField;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIView *statusBadgeView;
@property (nonatomic, strong) UIView *statusDotView;
@property (nonatomic, strong) UILabel *statusBadgeLabel;
@property (nonatomic, strong) UILabel *statsLabel;
@property (nonatomic, strong) NSTimer *updateTimer;

// Toggles UI
@property (nonatomic, strong) UISwitch *dualMicSwitch;
@property (nonatomic, strong) UISwitch *lowCutSwitch;
@property (nonatomic, strong) UISwitch *declickerSwitch;
@property (nonatomic, strong) UISwitch *noiseGateSwitch;
@property (nonatomic, strong) UISwitch *peakLimiterSwitch;
@property (nonatomic, strong) UISlider *gainSlider;
@property (nonatomic, strong) UILabel *gainValueLabel;

- (void)startStreaming;
- (void)stopStreaming;

@end
