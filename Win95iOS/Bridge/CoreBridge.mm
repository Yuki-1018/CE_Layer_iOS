#import "CoreBridge.h"

#include <libretro.h>
#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

extern "C" void dbp_win95_flush_disk(void);

static NSString * const Win95CoreErrorDomain = @"Win95Core";

@interface Win95VideoFrame ()
@property(nonatomic, readwrite) NSData *data;
@property(nonatomic, readwrite) NSInteger width;
@property(nonatomic, readwrite) NSInteger height;
@property(nonatomic, readwrite) NSInteger bytesPerRow;
@property(nonatomic, readwrite) uint64_t generation;
@end

@implementation Win95VideoFrame
@end

namespace {

enum class PendingOperation { None, Save, Load, MountCD, EjectCD, Flush };

struct Operation {
    PendingOperation kind = PendingOperation::None;
    std::string path;
    Win95Completion completion = nil;
};

static __weak Win95CoreBridge *gBridge;
static std::atomic<retro_keyboard_event_t> gKeyboardCallback{nullptr};
static retro_disk_control_ext_callback gDiskControl = {};
static bool gHasDiskControl = false;

static NSError *CoreError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:Win95CoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static void CoreLog(enum retro_log_level level, const char *format, ...) {
    va_list args;
    va_start(args, format);
    char message[2048];
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    const char *label = level == RETRO_LOG_ERROR ? "ERROR" : level == RETRO_LOG_WARN ? "WARN" : level == RETRO_LOG_DEBUG ? "DEBUG" : "INFO";
    fprintf(stderr, "[DOSBoxPure:%s] %s", label, message);
}

} // namespace

@interface Win95CoreBridge () {
    dispatch_queue_t _emulationQueue;
    std::atomic_bool _running;
    std::atomic_bool _paused;
    std::atomic_bool _stopRequested;
    std::atomic_bool _resetRequested;
    std::atomic_int _mouseX;
    std::atomic_int _mouseY;
    std::atomic_bool _leftButton;
    std::atomic_bool _rightButton;

    std::mutex _videoMutex;
    std::vector<uint8_t> _video;
    NSInteger _videoWidth;
    NSInteger _videoHeight;
    NSInteger _videoPitch;
    uint64_t _videoGeneration;

    std::mutex _audioMutex;
    std::deque<int16_t> _audio;

    std::mutex _operationMutex;
    std::deque<Operation> _operations;
    std::unordered_map<std::string, unsigned> _cdImageIndices;
    int _activeCDIndex;

    std::string _saveDirectory;
    std::string _systemDirectory;
    std::string _contentPath;
    std::unordered_map<std::string, std::string> _options;
}
- (void)runDiskPath:(NSString *)path completion:(Win95Completion)completion;
- (void)processOperations;
- (void)finishOperation:(Win95Completion)completion error:(NSError * _Nullable)error;
- (bool)environmentCommand:(unsigned)command data:(void *)data;
- (void)receiveVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch;
- (size_t)receiveAudio:(const int16_t *)data frames:(size_t)frames;
- (int16_t)inputStatePort:(unsigned)port device:(unsigned)device index:(unsigned)index identifier:(unsigned)identifier;
@end

static bool EnvironmentCallback(unsigned command, void *data) {
    Win95CoreBridge *bridge = gBridge;
    return bridge ? [bridge environmentCommand:command data:data] : false;
}

static void VideoCallback(const void *data, unsigned width, unsigned height, size_t pitch) {
    Win95CoreBridge *bridge = gBridge;
    if (bridge && data && data != RETRO_HW_FRAME_BUFFER_VALID) [bridge receiveVideo:data width:width height:height pitch:pitch];
}

static size_t AudioCallback(const int16_t *data, size_t frames) {
    Win95CoreBridge *bridge = gBridge;
    return bridge ? [bridge receiveAudio:data frames:frames] : frames;
}

static void InputPollCallback(void) {}

static int16_t InputStateCallback(unsigned port, unsigned device, unsigned index, unsigned identifier) {
    Win95CoreBridge *bridge = gBridge;
    return bridge ? [bridge inputStatePort:port device:device index:index identifier:identifier] : 0;
}

@implementation Win95CoreBridge

- (instancetype)initWithSaveDirectory:(NSURL *)saveDirectory systemDirectory:(NSURL *)systemDirectory {
    self = [super init];
    if (self) {
        _emulationQueue = dispatch_queue_create("jp.example.win95.emulation", DISPATCH_QUEUE_SERIAL);
        _running = false;
        _paused = false;
        _stopRequested = false;
        _resetRequested = false;
        _mouseX = _mouseY = 0;
        _leftButton = _rightButton = false;
        _videoWidth = _videoHeight = _videoPitch = 0;
        _videoGeneration = 0;
        _activeCDIndex = -1;
        _saveDirectory = saveDirectory.fileSystemRepresentation;
        _systemDirectory = systemDirectory.fileSystemRepresentation;
        _options = {
            {"dosbox_pure_force60fps", "true"},
            {"dosbox_pure_savestate", "on"},
            {"dosbox_pure_strict_mode", "false"},
            {"dosbox_pure_conf", "false"},
            {"dosbox_pure_menu_time", "99"},
            {"dosbox_pure_mouse_input", "true"},
            {"dosbox_pure_mouse_speed_factor", "1.0"},
            {"dosbox_pure_cycles", "77000"},
            {"dosbox_pure_cycles_max", "77000"},
            {"dosbox_pure_machine", "svga"},
            {"dosbox_pure_svga", "svga_s3"},
            {"dosbox_pure_svgamem", "2"},
            {"dosbox_pure_voodoo", "off"},
            {"dosbox_pure_voodoo_perf", "0"},
            {"dosbox_pure_memory_size", "64"},
            {"dosbox_pure_cpu_type", "pentium_slow"},
            {"dosbox_pure_cpu_core", "normal"},
            {"dosbox_pure_bootos_ramdisk", "diff"},
            {"dosbox_pure_bootos_forcenormal", "true"},
            {"dosbox_pure_audiorate", "48000"},
            {"dosbox_pure_sblaster_type", "sb16"},
            {"dosbox_pure_sblaster_conf", "A220 I7 D1 H5"},
            {"dosbox_pure_gus", "false"},
            {"dosbox_pure_tandysound", "off"},
            {"dosbox_pure_aspect_correction", "true"}
        };
    }
    return self;
}

- (BOOL)isRunning { return _running.load(); }
- (BOOL)isPaused { return _paused.load(); }

- (void)startWithDiskURL:(NSURL *)diskURL completion:(Win95Completion)completion {
    if (_running.exchange(true)) {
        [self finishOperation:completion error:CoreError(1, @"The virtual machine is already running.")];
        return;
    }
    _stopRequested = false;
    _paused = false;
    NSString *path = diskURL.path;
    dispatch_async(_emulationQueue, ^{ [self runDiskPath:path completion:completion]; });
}

- (void)runDiskPath:(NSString *)path completion:(Win95Completion)completion {
    @autoreleasepool {
        gBridge = self;
        gKeyboardCallback = nullptr;
        gHasDiskControl = false;
        _cdImageIndices.clear();
        _activeCDIndex = -1;
        _contentPath = path.fileSystemRepresentation;
        _contentPath += "#I*SVGA (Super Video Graphics Array)";

        retro_set_environment(EnvironmentCallback);
        retro_set_video_refresh(VideoCallback);
        retro_set_audio_sample_batch(AudioCallback);
        retro_set_input_poll(InputPollCallback);
        retro_set_input_state(InputStateCallback);
        retro_init();

        retro_game_info game = {};
        game.path = _contentPath.c_str();
        if (!retro_load_game(&game)) {
            retro_deinit();
            gKeyboardCallback = nullptr;
            gHasDiskControl = false;
            _cdImageIndices.clear();
            _activeCDIndex = -1;
            gBridge = nil;
            _running = false;
            [self finishOperation:completion error:CoreError(2, @"DOSBox Pure could not load the disk image.")];
            return;
        }

        retro_system_av_info av = {};
        retro_get_system_av_info(&av);
        [self finishOperation:completion error:nil];
        if (self.statusHandler) dispatch_async(dispatch_get_main_queue(), ^{ self.statusHandler(@"Running"); });

        using Clock = std::chrono::steady_clock;
        auto deadline = Clock::now();
        while (!_stopRequested.load()) {
            @autoreleasepool {
                [self processOperations];
                if (_resetRequested.exchange(false)) retro_reset();
                if (!_paused.load()) retro_run();
                else std::this_thread::sleep_for(std::chrono::milliseconds(8));
            }
            deadline += std::chrono::microseconds(16667);
            auto now = Clock::now();
            if (deadline > now) std::this_thread::sleep_until(deadline);
            else deadline = now;
        }

        dbp_win95_flush_disk();
        retro_unload_game();
        retro_deinit();
        gKeyboardCallback = nullptr;
        gHasDiskControl = false;
        _cdImageIndices.clear();
        _activeCDIndex = -1;
        gBridge = nil;
        _running = false;
        _paused = false;
        if (self.statusHandler) dispatch_async(dispatch_get_main_queue(), ^{ self.statusHandler(@"Stopped"); });
    }
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    if (!_running.load()) { if (completion) completion(); return; }
    _stopRequested = true;
    dispatch_async(_emulationQueue, ^{ if (completion) dispatch_async(dispatch_get_main_queue(), completion); });
}

- (void)setEmulationPaused:(BOOL)paused {
    _paused = paused;
    if (paused) [self flushDisk];
    if (self.statusHandler) dispatch_async(dispatch_get_main_queue(), ^{ self.statusHandler(paused ? @"Paused" : @"Running"); });
}

- (void)reset { _resetRequested = true; }

- (void)enqueueOperation:(Operation)operation {
    std::lock_guard<std::mutex> lock(_operationMutex);
    _operations.push_back(std::move(operation));
}

- (void)flushDisk {
    if (_running.load()) [self enqueueOperation:Operation{PendingOperation::Flush, {}, nil}];
}

- (void)saveStateToURL:(NSURL *)url completion:(Win95Completion)completion {
    if (!_running.load()) { [self finishOperation:completion error:CoreError(8, @"The virtual machine is not running.")]; return; }
    [self enqueueOperation:Operation{PendingOperation::Save, url.fileSystemRepresentation, [completion copy]}];
}

- (void)loadStateFromURL:(NSURL *)url completion:(Win95Completion)completion {
    if (!_running.load()) { [self finishOperation:completion error:CoreError(8, @"The virtual machine is not running.")]; return; }
    [self enqueueOperation:Operation{PendingOperation::Load, url.fileSystemRepresentation, [completion copy]}];
}

- (void)mountCDAtURL:(NSURL *)url completion:(Win95Completion)completion {
    if (!_running.load()) { [self finishOperation:completion error:CoreError(8, @"The virtual machine is not running.")]; return; }
    [self enqueueOperation:Operation{PendingOperation::MountCD, url.fileSystemRepresentation, [completion copy]}];
}

- (void)ejectCD {
    if (_running.load()) [self enqueueOperation:Operation{PendingOperation::EjectCD, {}, nil}];
}

- (void)processOperations {
    std::deque<Operation> operations;
    {
        std::lock_guard<std::mutex> lock(_operationMutex);
        operations.swap(_operations);
    }
    for (Operation &operation : operations) {
        NSError *error = nil;
        switch (operation.kind) {
            case PendingOperation::Flush:
                dbp_win95_flush_disk();
                break;
            case PendingOperation::Save: {
                dbp_win95_flush_disk();
                size_t size = retro_serialize_size();
                std::vector<uint8_t> bytes(size);
                if (!size || !retro_serialize(bytes.data(), bytes.size())) error = CoreError(3, @"The VM state could not be serialized.");
                else {
                    NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
                    NSString *path = [NSString stringWithUTF8String:operation.path.c_str()];
                    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) error = error ?: CoreError(4, @"The VM state could not be written.");
                }
                break;
            }
            case PendingOperation::Load: {
                NSString *path = [NSString stringWithUTF8String:operation.path.c_str()];
                NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
                if (data && !retro_unserialize(data.bytes, data.length)) error = CoreError(5, @"This save state is invalid or incompatible.");
                break;
            }
            case PendingOperation::MountCD: {
                if (!gHasDiskControl || !gDiskControl.set_eject_state || !gDiskControl.set_image_index ||
                    !gDiskControl.get_num_images || !gDiskControl.add_image_index || !gDiskControl.replace_image_index) {
                    error = CoreError(6, @"CD-ROM control is unavailable.");
                    break;
                }

                unsigned index = 0;
                auto existing = _cdImageIndices.find(operation.path);
                if (existing != _cdImageIndices.end()) {
                    index = existing->second;
                }

                if (_activeCDIndex >= 0 && (existing == _cdImageIndices.end() || _activeCDIndex != (int)index)) {
                    if (!gDiskControl.set_image_index((unsigned)_activeCDIndex) || !gDiskControl.set_eject_state(true)) {
                        error = CoreError(7, @"The current CD image could not be ejected.");
                        break;
                    }
                    _activeCDIndex = -1;
                }

                if (existing == _cdImageIndices.end()) {
                    index = gDiskControl.get_num_images();
                    retro_game_info info = {};
                    info.path = operation.path.c_str();
                    if (!gDiskControl.add_image_index() || !gDiskControl.set_image_index(index) ||
                        !gDiskControl.replace_image_index(index, &info)) {
                        error = CoreError(7, @"The CD image could not be registered.");
                        break;
                    }
                    _cdImageIndices.emplace(operation.path, index);
                }
                if (!gDiskControl.set_image_index(index) || !gDiskControl.set_eject_state(false)) {
                    error = CoreError(7, @"The CD image could not be mounted.");
                    break;
                }
                _activeCDIndex = (int)index;
                break;
            }
            case PendingOperation::EjectCD:
                if (_activeCDIndex >= 0 && gHasDiskControl && gDiskControl.set_image_index && gDiskControl.set_eject_state) {
                    gDiskControl.set_image_index((unsigned)_activeCDIndex);
                    gDiskControl.set_eject_state(true);
                    _activeCDIndex = -1;
                }
                break;
            case PendingOperation::None:
                break;
        }
        [self finishOperation:operation.completion error:error];
    }
}

- (void)finishOperation:(Win95Completion)completion error:(NSError *)error {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
}

- (Win95VideoFrame *)latestVideoFrameAfterGeneration:(uint64_t)generation {
    std::lock_guard<std::mutex> lock(_videoMutex);
    if (_video.empty() || generation == _videoGeneration) return nil;
    Win95VideoFrame *frame = [Win95VideoFrame new];
    frame.data = [NSData dataWithBytes:_video.data() length:_video.size()];
    frame.width = _videoWidth;
    frame.height = _videoHeight;
    frame.bytesPerRow = _videoPitch;
    frame.generation = _videoGeneration;
    return frame;
}

- (void)receiveVideo:(const void *)data width:(unsigned)width height:(unsigned)height pitch:(size_t)pitch {
    std::lock_guard<std::mutex> lock(_videoMutex);
    _video.resize(pitch * height);
    memcpy(_video.data(), data, _video.size());
    _videoWidth = width;
    _videoHeight = height;
    _videoPitch = pitch;
    ++_videoGeneration;
}

- (size_t)receiveAudio:(const int16_t *)data frames:(size_t)frames {
    std::lock_guard<std::mutex> lock(_audioMutex);
    const size_t samples = frames * 2;
    const size_t capacity = 48000 * 2;
    while (_audio.size() + samples > capacity && !_audio.empty()) _audio.pop_front();
    _audio.insert(_audio.end(), data, data + samples);
    return frames;
}

- (NSUInteger)readAudioFrames:(int16_t *)buffer maxFrames:(NSUInteger)maxFrames {
    std::lock_guard<std::mutex> lock(_audioMutex);
    NSUInteger frames = MIN(maxFrames, _audio.size() / 2);
    for (NSUInteger i = 0; i < frames * 2; ++i) { buffer[i] = _audio.front(); _audio.pop_front(); }
    if (frames < maxFrames) memset(buffer + frames * 2, 0, (maxFrames - frames) * 2 * sizeof(int16_t));
    return frames;
}

- (void)sendKey:(unsigned)keyCode pressed:(BOOL)pressed {
    retro_keyboard_event_t callback = gKeyboardCallback.load();
    if (_running.load() && callback) callback(pressed, keyCode, 0, 0);
}

- (void)addMouseDeltaX:(NSInteger)deltaX deltaY:(NSInteger)deltaY {
    _mouseX.fetch_add((int)MAX(-32767, MIN(32767, deltaX)));
    _mouseY.fetch_add((int)MAX(-32767, MIN(32767, deltaY)));
}

- (void)setLeftMouseButton:(BOOL)pressed { _leftButton = pressed; }
- (void)setRightMouseButton:(BOOL)pressed { _rightButton = pressed; }

- (int16_t)inputStatePort:(unsigned)port device:(unsigned)device index:(unsigned)index identifier:(unsigned)identifier {
    if (port || device != RETRO_DEVICE_MOUSE) return 0;
    switch (identifier) {
        case RETRO_DEVICE_ID_MOUSE_X: return (int16_t)MAX(-32767, MIN(32767, _mouseX.exchange(0)));
        case RETRO_DEVICE_ID_MOUSE_Y: return (int16_t)MAX(-32767, MIN(32767, _mouseY.exchange(0)));
        case RETRO_DEVICE_ID_MOUSE_LEFT: return _leftButton.load() ? 1 : 0;
        case RETRO_DEVICE_ID_MOUSE_RIGHT: return _rightButton.load() ? 1 : 0;
        default: return 0;
    }
}

- (bool)environmentCommand:(unsigned)command data:(void *)data {
    switch (command) {
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            *(const char **)data = _saveDirectory.c_str(); return true;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            *(const char **)data = _systemDirectory.c_str(); return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            retro_variable *variable = static_cast<retro_variable *>(data);
            auto found = _options.find(variable->key ? variable->key : "");
            variable->value = found == _options.end() ? nullptr : found->second.c_str();
            return found != _options.end();
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            *(bool *)data = false; return true;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            return *(retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
        case RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK:
            gKeyboardCallback.store(static_cast<retro_keyboard_callback *>(data)->callback); return true;
        case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE:
            gDiskControl = *static_cast<retro_disk_control_ext_callback *>(data); gHasDiskControl = true; return true;
        case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
            *(unsigned *)data = 1; return true;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            static_cast<retro_log_callback *>(data)->log = CoreLog; return true;
        case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
            *(unsigned *)data = 2; return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            *(bool *)data = true; return true;
        case RETRO_ENVIRONMENT_GET_LANGUAGE:
            *(unsigned *)data = RETRO_LANGUAGE_ENGLISH; return true;
        case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
            *(int *)data = 3; return true;
        case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
            *(unsigned *)data = RETRO_HW_CONTEXT_NONE; return true;
        case RETRO_ENVIRONMENT_GET_JIT_CAPABLE:
            *(bool *)data = false; return true;
        case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
        case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
        case RETRO_ENVIRONMENT_SET_GEOMETRY:
        case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
        case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
            return true;
        case RETRO_ENVIRONMENT_SET_MESSAGE: {
            retro_message *message = static_cast<retro_message *>(data);
            if (self.statusHandler && message->msg) {
                NSString *text = [NSString stringWithUTF8String:message->msg];
                dispatch_async(dispatch_get_main_queue(), ^{ self.statusHandler(text); });
            }
            return true;
        }
        case RETRO_ENVIRONMENT_SHUTDOWN:
            _stopRequested = true; return true;
        default:
            return false;
    }
}

@end
