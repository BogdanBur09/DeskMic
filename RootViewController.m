#import "RootViewController.h"
#import <math.h>

#define AUDIO_SAMPLE_RATE 16000.0
#define AUDIO_CHANNELS 1
#define AUDIO_BITS_PER_SAMPLE 16
#define AUDIO_BUFFER_SIZE 1024
#define AUDIO_NUM_BUFFERS 3
#define UDP_PORT 50005

static void DeskMicAudioInputCallback(
    void *inUserData,
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    const AudioTimeStamp *inStartTime,
    UInt32 inNumberPacketDescriptions,
    const AudioStreamPacketDescription *inPacketDescs
) {
    RootViewController *selfRef = (__bridge RootViewController *)inUserData;
    if (!selfRef || !selfRef->_isStreaming) {
        return;
    }

    if (inBuffer->mAudioDataByteSize > 0 && selfRef->_socketFd >= 0) {
        int16_t *samples = (int16_t *)inBuffer->mAudioData;
        int numSamples = inBuffer->mAudioDataByteSize / sizeof(int16_t);

        // 1. 80 Hz Low-Cut / High-Pass Filter (Removes mechanical desk rumble)
        if (selfRef->_lowCutEnabled) {
            // Cutoff ~80 Hz at 16000 Hz: alpha = 0.96954f
            const float alpha = 0.96954f;
            float prevIn = selfRef->_hpPrevIn;
            float prevOut = selfRef->_hpPrevOut;
            for (int i = 0; i < numSamples; i++) {
                float inVal = (float)samples[i];
                float outVal = alpha * (prevOut + inVal - prevIn);
                prevIn = inVal;
                prevOut = outVal;
                if (outVal > 32767.0f) outVal = 32767.0f;
                else if (outVal < -32768.0f) outVal = -32768.0f;
                samples[i] = (int16_t)outVal;
            }
            selfRef->_hpPrevIn = prevIn;
            selfRef->_hpPrevOut = prevOut;
        }

        // 2. Mouse De-Clicker (Microswitch impulse suppression)
        if (selfRef->_declickerEnabled && numSamples > 2) {
            for (int i = 1; i < numSamples - 1; i++) {
                int delta = (int)samples[i] - (int)samples[i-1];
                if (abs(delta) > 4200) {
                    samples[i] = (int16_t)(((int)samples[i-1] * 7 + (int)samples[i+1] * 3) / 10);
                }
            }
        }

        // 3. Real-time Noise Gate (Silences stream during speech pauses to kill keyboard clatter)
        if (selfRef->_noiseGateEnabled) {
            int maxPeak = 0;
            for (int i = 0; i < numSamples; i++) {
                int absVal = abs((int)samples[i]);
                if (absVal > maxPeak) maxPeak = absVal;
            }

            // Speech threshold: ~ -36 dBFS (~450 in 16-bit)
            const int gateThreshold = 450;
            // Hold open for ~160ms (5 buffers * 32ms) to prevent cutting off trailing syllables
            if (maxPeak >= gateThreshold) {
                selfRef->_gateHoldCounter = 5;
            } else if (selfRef->_gateHoldCounter > 0) {
                selfRef->_gateHoldCounter--;
            }

            float targetGain = (selfRef->_gateHoldCounter > 0) ? 1.0f : 0.0f;
            float currentGain = selfRef->_gateGain;
            float gainDelta = (targetGain - currentGain) / (float)numSamples;

            for (int i = 0; i < numSamples; i++) {
                currentGain += gainDelta;
                samples[i] = (int16_t)((float)samples[i] * currentGain);
            }
            selfRef->_gateGain = targetGain;
        }

        // 3. Fast Peak Limiter / Soft Clipper (Tames sharp instantaneous key bottoming clicks)
        if (selfRef->_peakLimiterEnabled) {
            const float threshold = 18000.0f; // ~ -5 dBFS
            const float maxVal = 32767.0f;
            for (int i = 0; i < numSamples; i++) {
                float s = (float)samples[i];
                float absS = fabsf(s);
                if (absS > threshold) {
                    float excess = absS - threshold;
                    float compressed = threshold + (maxVal - threshold) * (excess / (excess + 10000.0f));
                    samples[i] = (int16_t)(s > 0 ? compressed : -compressed);
                }
            }
        }

        // Transmit processed audio buffer via UDP
        ssize_t sent = sendto(
            selfRef->_socketFd,
            inBuffer->mAudioData,
            inBuffer->mAudioDataByteSize,
            0,
            (struct sockaddr *)&selfRef->_destAddr,
            sizeof(selfRef->_destAddr)
        );
        if (sent > 0) {
            selfRef->_packetsSent++;
            selfRef->_bytesSent += (uint64_t)sent;
        }
    }

    if (selfRef->_isStreaming) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    _socketFd = -1;
    _audioQueue = NULL;
    _isStreaming = NO;
    _packetsSent = 0;
    _bytesSent = 0;

    _hpPrevIn = 0.0f;
    _hpPrevOut = 0.0f;
    _gateGain = 1.0f;
    _gateHoldCounter = 0;

    self.view.backgroundColor = [UIColor colorWithRed:18/255.0 green:18/255.0 blue:20/255.0 alpha:1.0];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    [self loadSettings];
    [self setupUI];
    [self updateUI];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)loadSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"deskmic_dual_mic"] == nil) {
        // First launch defaults
        _dualMicEnabled = YES;
        _lowCutEnabled = YES;
        _declickerEnabled = YES;
        _noiseGateEnabled = YES;
        _peakLimiterEnabled = YES;
        _hwGainValue = 0.5f; // Safe natural default (0.5x)
    } else {
        _dualMicEnabled = [defaults boolForKey:@"deskmic_dual_mic"];
        _lowCutEnabled = [defaults boolForKey:@"deskmic_low_cut"];
        _declickerEnabled = [defaults boolForKey:@"deskmic_declicker"];
        _noiseGateEnabled = [defaults boolForKey:@"deskmic_noise_gate"];
        _peakLimiterEnabled = [defaults boolForKey:@"deskmic_peak_limiter"];
        _hwGainValue = [defaults floatForKey:@"deskmic_hw_gain"];
        if (_hwGainValue <= 0.01f || _hwGainValue > 1.0f) _hwGainValue = 0.5f;
    }
}

- (void)saveSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:_dualMicEnabled forKey:@"deskmic_dual_mic"];
    [defaults setBool:_lowCutEnabled forKey:@"deskmic_low_cut"];
    [defaults setBool:_declickerEnabled forKey:@"deskmic_declicker"];
    [defaults setBool:_noiseGateEnabled forKey:@"deskmic_noise_gate"];
    [defaults setBool:_peakLimiterEnabled forKey:@"deskmic_peak_limiter"];
    [defaults setFloat:_hwGainValue forKey:@"deskmic_hw_gain"];
    [defaults synchronize];
}

- (void)setupUI {
    CGFloat screenWidth = 320.0;
    CGFloat screenHeight = self.view.bounds.size.height > 0 ? self.view.bounds.size.height : 480.0;

    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, screenHeight)];
    self.scrollView.backgroundColor = [UIColor clearColor];
    self.scrollView.showsVerticalScrollIndicator = YES;
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, 750)];
    self.contentView.backgroundColor = [UIColor clearColor];
    [self.scrollView addSubview:self.contentView];
    self.scrollView.contentSize = self.contentView.frame.size;

    // Header Title
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 28, screenWidth - 32, 28)];
    titleLabel.text = @"DeskMic";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:25];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.contentView addSubview:titleLabel];

    // Subtitle
    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 56, screenWidth - 32, 16)];
    subtitleLabel.text = @"iPhone 4s UDP Microphone Streamer";
    subtitleLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    subtitleLabel.font = [UIFont systemFontOfSize:11];
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.contentView addSubview:subtitleLabel];

    // Status Badge
    self.statusBadgeView = [[UIView alloc] initWithFrame:CGRectMake((screenWidth - 140) / 2.0, 78, 140, 24)];
    self.statusBadgeView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    self.statusBadgeView.layer.cornerRadius = 12.0;
    self.statusBadgeView.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1.0].CGColor;
    self.statusBadgeView.layer.borderWidth = 1.0;
    [self.contentView addSubview:self.statusBadgeView];

    self.statusDotView = [[UIView alloc] initWithFrame:CGRectMake(10, 8, 8, 8)];
    self.statusDotView.layer.cornerRadius = 4.0;
    self.statusDotView.backgroundColor = [UIColor colorWithRed:255/255.0 green:69/255.0 blue:58/255.0 alpha:1.0];
    [self.statusBadgeView addSubview:self.statusDotView];

    self.statusBadgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 0, 106, 24)];
    self.statusBadgeLabel.textColor = [UIColor whiteColor];
    self.statusBadgeLabel.font = [UIFont boldSystemFontOfSize:11];
    self.statusBadgeLabel.text = @"DISCONNECTED";
    self.statusBadgeLabel.textAlignment = NSTextAlignmentCenter;
    [self.statusBadgeView addSubview:self.statusBadgeLabel];

    // Target PC IP Input
    UILabel *inputHeaderLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 110, screenWidth - 40, 16)];
    inputHeaderLabel.text = @"TARGET PC IP ADDRESS";
    inputHeaderLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    inputHeaderLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.contentView addSubview:inputHeaderLabel];

    self.ipTextField = [[UITextField alloc] initWithFrame:CGRectMake(20, 128, screenWidth - 40, 42)];
    self.ipTextField.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    self.ipTextField.layer.cornerRadius = 8.0;
    self.ipTextField.layer.borderWidth = 1.0;
    self.ipTextField.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    self.ipTextField.textColor = [UIColor whiteColor];
    self.ipTextField.font = [UIFont boldSystemFontOfSize:16];
    self.ipTextField.textAlignment = NSTextAlignmentCenter;
    self.ipTextField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.ipTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.ipTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.ipTextField.returnKeyType = UIReturnKeyDone;
    self.ipTextField.delegate = self;

    NSString *lastIP = [[NSUserDefaults standardUserDefaults] stringForKey:@"last_pc_ip"];
    if (lastIP && lastIP.length > 0) {
        self.ipTextField.text = lastIP;
    }
    self.ipTextField.placeholder = @"e.g. 192.168.1.138";
    [self.contentView addSubview:self.ipTextField];

    // Big Toggle Button
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(20, 178, screenWidth - 40, 46);
    self.toggleButton.layer.cornerRadius = 8.0;
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.toggleButton addTarget:self action:@selector(toggleStreamingPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.toggleButton];

    // AUDIO PROCESSING RACK / TOGGLES CARD
    UIView *togglesCard = [[UIView alloc] initWithFrame:CGRectMake(20, 234, screenWidth - 40, 310)];
    togglesCard.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    togglesCard.layer.cornerRadius = 8.0;
    togglesCard.layer.borderWidth = 1.0;
    togglesCard.layer.borderColor = [UIColor colorWithWhite:0.2 alpha:1.0].CGColor;
    [self.contentView addSubview:togglesCard];

    UILabel *rackTitle = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, screenWidth - 64, 16)];
    rackTitle.text = @"AUDIO ENHANCEMENT CONTROLS";
    rackTitle.textColor = [UIColor colorWithRed:0 green:185/255.0 blue:200/255.0 alpha:1.0];
    rackTitle.font = [UIFont boldSystemFontOfSize:11];
    [togglesCard addSubview:rackTitle];

    // 1. Dual-Mic Denoise
    self.dualMicSwitch = [self createSwitchRowInView:togglesCard
                                                   y:32
                                               label:@"Dual-Mic Denoise"
                                            subtitle:@"Apple VoiceChat differential cancellation"
                                              target:@selector(dualMicChanged:)
                                             initial:_dualMicEnabled];

    // 2. 80 Hz Low-Cut
    self.lowCutSwitch = [self createSwitchRowInView:togglesCard
                                                  y:74
                                              label:@"80Hz Low-Cut (Rumble)"
                                           subtitle:@"Eliminates mechanical desk thumps"
                                             target:@selector(lowCutChanged:)
                                            initial:_lowCutEnabled];

    // 3. Mouse De-Clicker
    self.declickerSwitch = [self createSwitchRowInView:togglesCard
                                                     y:116
                                                 label:@"Mouse De-Clicker"
                                              subtitle:@"Suppresses sharp microswitch clicks"
                                                target:@selector(declickerChanged:)
                                               initial:_declickerEnabled];

    // 4. Smart Noise Gate
    self.noiseGateSwitch = [self createSwitchRowInView:togglesCard
                                                     y:158
                                                 label:@"Smart Noise Gate"
                                              subtitle:@"Silences keyboard when not speaking"
                                                target:@selector(noiseGateChanged:)
                                               initial:_noiseGateEnabled];

    // 5. Peak Limiter
    self.peakLimiterSwitch = [self createSwitchRowInView:togglesCard
                                                       y:200
                                                   label:@"Peak Limiter / Anti-Spike"
                                                subtitle:@"Suppresses loud sudden key clacks"
                                                  target:@selector(peakLimiterChanged:)
                                                 initial:_peakLimiterEnabled];

    // 6. Hardware Gain (Smooth slider with Default button)
    CGFloat cardWidth = screenWidth - 40;
    UILabel *gainLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 244, 120, 16)];
    gainLbl.text = @"Hardware Gain";
    gainLbl.textColor = [UIColor whiteColor];
    gainLbl.font = [UIFont boldSystemFontOfSize:13];
    [togglesCard addSubview:gainLbl];

    self.gainValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(cardWidth - 140, 244, 128, 16)];
    self.gainValueLabel.textAlignment = NSTextAlignmentRight;
    self.gainValueLabel.textColor = [UIColor colorWithRed:0 green:185/255.0 blue:200/255.0 alpha:1.0];
    self.gainValueLabel.font = [UIFont boldSystemFontOfSize:12];
    if (fabsf(_hwGainValue - 0.5f) < 0.04f) {
        self.gainValueLabel.text = @"0.50x (Default)";
    } else {
        self.gainValueLabel.text = [NSString stringWithFormat:@"%.2fx", _hwGainValue];
    }
    [togglesCard addSubview:self.gainValueLabel];

    self.gainSlider = [[UISlider alloc] initWithFrame:CGRectMake(12, 268, cardWidth - 84, 30)];
    self.gainSlider.minimumValue = 0.05f;
    self.gainSlider.maximumValue = 1.0f;
    self.gainSlider.value = _hwGainValue;
    self.gainSlider.continuous = YES;
    self.gainSlider.tintColor = [UIColor colorWithRed:0 green:185/255.0 blue:200/255.0 alpha:1.0];
    [self.gainSlider addTarget:self action:@selector(gainSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [togglesCard addSubview:self.gainSlider];

    UIButton *defaultBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    defaultBtn.frame = CGRectMake(cardWidth - 62, 268, 50, 28);
    defaultBtn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    defaultBtn.layer.cornerRadius = 6.0;
    defaultBtn.layer.borderWidth = 1.0;
    defaultBtn.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    [defaultBtn setTitle:@"Default" forState:UIControlStateNormal];
    [defaultBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    defaultBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    [defaultBtn addTarget:self action:@selector(resetDefaultGainPressed) forControlEvents:UIControlEventTouchUpInside];
    [togglesCard addSubview:defaultBtn];

    // STATS & TELEMETRY CARD
    UIView *statsCard = [[UIView alloc] initWithFrame:CGRectMake(20, 554, screenWidth - 40, 170)];
    statsCard.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
    statsCard.layer.cornerRadius = 8.0;
    statsCard.layer.borderWidth = 1.0;
    statsCard.layer.borderColor = [UIColor colorWithWhite:0.18 alpha:1.0].CGColor;
    [self.contentView addSubview:statsCard];

    self.statsLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, screenWidth - 64, 154)];
    self.statsLabel.numberOfLines = 0;
    self.statsLabel.font = [UIFont systemFontOfSize:11];
    self.statsLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    [statsCard addSubview:self.statsLabel];
}

- (UISwitch *)createSwitchRowInView:(UIView *)parentView
                           y:(CGFloat)y
                       label:(NSString *)label
                    subtitle:(NSString *)subtitle
                      target:(SEL)action
                     initial:(BOOL)initial {
    CGFloat cardWidth = parentView.bounds.size.width;

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, cardWidth - 80, 16)];
    titleLbl.text = label;
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.font = [UIFont boldSystemFontOfSize:13];
    [parentView addSubview:titleLbl];

    UILabel *subLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, y + 16, cardWidth - 80, 14)];
    subLbl.text = subtitle;
    subLbl.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    subLbl.font = [UIFont systemFontOfSize:10];
    [parentView addSubview:subLbl];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(cardWidth - 64, y + 2, 51, 31)];
    sw.on = initial;
    sw.onTintColor = [UIColor colorWithRed:48/255.0 green:190/255.0 blue:75/255.0 alpha:1.0];
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [parentView addSubview:sw];
    return sw;
}

#pragma mark - Toggle Actions

- (void)dualMicChanged:(UISwitch *)sender {
    _dualMicEnabled = sender.isOn;
    [self saveSettings];
    [self applyAudioSessionConfiguration];
    [self updateStats];
}

- (void)lowCutChanged:(UISwitch *)sender {
    _lowCutEnabled = sender.isOn;
    _hpPrevIn = 0.0f;
    _hpPrevOut = 0.0f;
    [self saveSettings];
    [self updateStats];
}

- (void)declickerChanged:(UISwitch *)sender {
    _declickerEnabled = sender.isOn;
    [self saveSettings];
    [self updateStats];
}

- (void)noiseGateChanged:(UISwitch *)sender {
    _noiseGateEnabled = sender.isOn;
    _gateGain = 1.0f;
    _gateHoldCounter = 0;
    [self saveSettings];
    [self updateStats];
}

- (void)peakLimiterChanged:(UISwitch *)sender {
    _peakLimiterEnabled = sender.isOn;
    [self saveSettings];
    [self updateStats];
}

- (void)gainSliderChanged:(UISlider *)sender {
    _hwGainValue = sender.value;
    if (fabsf(_hwGainValue - 0.5f) < 0.04f) {
        self.gainValueLabel.text = @"0.50x (Default)";
    } else {
        self.gainValueLabel.text = [NSString stringWithFormat:@"%.2fx", _hwGainValue];
    }
    [self saveSettings];
    [self applyHardwareGain];
    [self updateStats];
}

- (void)resetDefaultGainPressed {
    _hwGainValue = 0.5f;
    self.gainSlider.value = 0.5f;
    self.gainValueLabel.text = @"0.50x (Default)";
    [self saveSettings];
    [self applyHardwareGain];
    [self updateStats];
}

- (void)applyAudioSessionConfiguration {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    NSString *mode = _dualMicEnabled ? AVAudioSessionModeVoiceChat : AVAudioSessionModeMeasurement;
    [session setMode:mode error:&error];
    if (error) {
        NSLog(@"[DeskMic] setMode error: %@", error);
    }
}

- (void)applyHardwareGain {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (session.isInputGainSettable) {
        NSError *gainError = nil;
        [session setInputGain:_hwGainValue error:&gainError];
        if (gainError) {
            NSLog(@"[DeskMic] setInputGain error: %@", gainError);
        }
    }
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)toggleStreamingPressed {
    [self dismissKeyboard];
    if (_isStreaming) {
        [self stopStreaming];
    } else {
        [self startStreaming];
    }
}

- (void)startStreaming {
    NSString *ip = [self.ipTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (ip.length == 0) {
        [self showAlertWithTitle:@"IP Required" message:@"Please enter your PC's IP address (shown on Windows receiver)."];
        return;
    }

    struct in_addr addr;
    if (inet_pton(AF_INET, [ip UTF8String], &addr) <= 0) {
        [self showAlertWithTitle:@"Invalid IP" message:@"Please enter a valid IPv4 address (e.g. 192.168.1.138)."];
        return;
    }

    [[NSUserDefaults standardUserDefaults] setObject:ip forKey:@"last_pc_ip"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    _socketFd = socket(AF_INET, SOCK_DGRAM, 0);
    if (_socketFd < 0) {
        [self showAlertWithTitle:@"Network Error" message:@"Failed to create UDP socket."];
        return;
    }

    memset(&_destAddr, 0, sizeof(_destAddr));
    _destAddr.sin_family = AF_INET;
    _destAddr.sin_port = htons(UDP_PORT);
    _destAddr.sin_addr = addr;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *audioSessionError = nil;
    [session setCategory:AVAudioSessionCategoryRecord error:&audioSessionError];

    // Configure Dual-Mic Mode (VoiceChat vs Measurement)
    [self applyAudioSessionConfiguration];

    [session setActive:YES error:&audioSessionError];

    // Configure Hardware Gain (0.8x vs 1.0x)
    [self applyHardwareGain];

    AudioStreamBasicDescription audioFormat;
    memset(&audioFormat, 0, sizeof(audioFormat));
    audioFormat.mSampleRate = AUDIO_SAMPLE_RATE;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    audioFormat.mBytesPerPacket = 2;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mBytesPerFrame = 2;
    audioFormat.mChannelsPerFrame = AUDIO_CHANNELS;
    audioFormat.mBitsPerChannel = AUDIO_BITS_PER_SAMPLE;
    audioFormat.mReserved = 0;

    OSStatus status = AudioQueueNewInput(
        &audioFormat,
        DeskMicAudioInputCallback,
        (__bridge void *)self,
        NULL,
        NULL,
        0,
        &_audioQueue
    );

    if (status != noErr) {
        [self showAlertWithTitle:@"Audio Queue Error" message:[NSString stringWithFormat:@"Failed to create AudioQueue (status: %d)", (int)status]];
        close(_socketFd);
        _socketFd = -1;
        return;
    }

    _isStreaming = YES;
    _packetsSent = 0;
    _bytesSent = 0;
    _gateGain = 1.0f;
    _gateHoldCounter = 0;

    for (int i = 0; i < AUDIO_NUM_BUFFERS; i++) {
        AudioQueueAllocateBuffer(_audioQueue, AUDIO_BUFFER_SIZE, &_audioBuffers[i]);
        AudioQueueEnqueueBuffer(_audioQueue, _audioBuffers[i], 0, NULL);
    }

    status = AudioQueueStart(_audioQueue, NULL);
    if (status != noErr) {
        [self showAlertWithTitle:@"Start Error" message:[NSString stringWithFormat:@"Failed to start AudioQueue (status: %d)", (int)status]];
        [self stopStreaming];
        return;
    }

    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                        target:self
                                                      selector:@selector(updateStats)
                                                      userInfo:nil
                                                       repeats:YES];
    [self updateUI];
}

- (void)stopStreaming {
    if (!_isStreaming && _socketFd < 0 && _audioQueue == NULL) {
        return;
    }

    _isStreaming = NO;

    if (self.updateTimer) {
        [self.updateTimer invalidate];
        self.updateTimer = nil;
    }

    if (_audioQueue != NULL) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }

    if (_socketFd >= 0) {
        close(_socketFd);
        _socketFd = -1;
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];

    [self updateUI];
}

- (void)updateUI {
    if (_isStreaming) {
        self.statusBadgeLabel.text = @"STREAMING";
        self.statusDotView.backgroundColor = [UIColor colorWithRed:48/255.0 green:209/255.0 blue:88/255.0 alpha:1.0];
        self.statusBadgeView.layer.borderColor = [UIColor colorWithRed:48/255.0 green:209/255.0 blue:88/255.0 alpha:0.6].CGColor;

        [self.toggleButton setTitle:@"STOP STREAMING" forState:UIControlStateNormal];
        self.toggleButton.backgroundColor = [UIColor colorWithRed:235/255.0 green:55/255.0 blue:55/255.0 alpha:1.0];
        self.ipTextField.enabled = NO;
        self.ipTextField.alpha = 0.6;
    } else {
        self.statusBadgeLabel.text = @"IDLE / READY";
        self.statusDotView.backgroundColor = [UIColor colorWithRed:255/255.0 green:69/255.0 blue:58/255.0 alpha:1.0];
        self.statusBadgeView.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1.0].CGColor;

        [self.toggleButton setTitle:@"START STREAMING" forState:UIControlStateNormal];
        self.toggleButton.backgroundColor = [UIColor colorWithRed:48/255.0 green:190/255.0 blue:75/255.0 alpha:1.0];
        self.ipTextField.enabled = YES;
        self.ipTextField.alpha = 1.0;
    }
    [self updateStats];
}

- (void)updateStats {
    NSString *ip = [self.ipTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (ip.length == 0) ip = @"(none)";

    double kbSent = (double)_bytesSent / 1024.0;
    NSString *statusStr = _isStreaming ? @"Active (Streaming)" : @"Stopped (Idle)";
    NSString *modeStr = _dualMicEnabled ? @"Dual-Mic Denoise (VoiceChat)" : @"Raw / Unfiltered (Measurement)";

    self.statsLabel.text = [NSString stringWithFormat:
        @"HARDWARE & DSP PROFILE\n"
        @"  • Mode: %@\n"
        @"  • Low-Cut: %@ | De-Clicker: %@\n"
        @"  • Gate: %@ | Limiter: %@\n"
        @"  • HW Gain: %.2fx (Zero-Drift Sync)\n\n"
        @"TELEMETRY & TRANSMISSION\n"
        @"  • Target: %@:%d (UDP)\n"
        @"  • State: %@\n"
        @"  • Packets: %llu  (%.1f KB)",
        modeStr,
        _lowCutEnabled ? @"ON" : @"OFF",
        _declickerEnabled ? @"ON" : @"OFF",
        _noiseGateEnabled ? @"ON" : @"OFF",
        _peakLimiterEnabled ? @"ON" : @"OFF",
        _hwGainValue,
        ip, UDP_PORT, statusStr, _packetsSent, kbSent];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:ok];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dealloc {
    [self stopStreaming];
}

@end
