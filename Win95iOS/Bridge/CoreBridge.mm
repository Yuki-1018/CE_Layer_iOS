#import "CoreBridge.h"

#include <libretro.h>
#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <deque>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <thread>
#include <unordered_map>
#include <unistd.h>
#include <vector>

extern "C" void dbp_win95_flush_disk(void);
extern "C" bool dbp_win95_guest_shutdown(void);
extern "C" void dbp_win95_set_initial_cd(const char *path);
extern "C" void dbp_win95_release_input(void);

static NSString * const Win95CoreErrorDomain = @"Win95Core";

@interface Win95VideoFrame ()
@property(nonatomic, readwrite) NSData *data;
@property(nonatomic, readwrite) NSInteger width;
@property(nonatomic, readwrite) NSInteger height;
@property(nonatomic, readwrite) NSInteger bytesPerRow;
@property(nonatomic, readwrite) double aspectRatio;
@property(nonatomic, readwrite) uint64_t generation;
@end

@implementation Win95VideoFrame
@end

namespace {

enum class PendingOperation { None, Flush, SaveSuspend, LoadSuspend, ReleaseInput };

struct KeyEvent {
    unsigned keyCode;
    bool pressed;
};

struct Operation {
    PendingOperation kind = PendingOperation::None;
    std::string path;
    Win95Completion completion = nil;
};

static __weak Win95CoreBridge *gBridge;
static std::atomic<retro_keyboard_event_t> gKeyboardCallback{nullptr};

static NSError *CoreError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:Win95CoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSError *SaveSuspendState(const std::string &path) {
    const size_t size = retro_serialize_size();
    if (!size) return CoreError(9, @"DOSBox Pure did not provide a suspend-state size.");

    const std::string partial = path + ".partial";
    int fd = open(partial.c_str(), O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) return CoreError(10, @"The suspend-state file could not be created.");
    if (ftruncate(fd, static_cast<off_t>(size)) != 0) {
        close(fd); unlink(partial.c_str());
        return CoreError(10, @"Space could not be reserved for the suspend state.");
    }
    void *mapping = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
        close(fd); unlink(partial.c_str());
        return CoreError(10, @"The suspend state could not be mapped into memory.");
    }

    const bool serialized = retro_serialize(mapping, size);
    const bool synchronized = serialized && msync(mapping, size, MS_SYNC) == 0 && fsync(fd) == 0;
    munmap(mapping, size);
    close(fd);
    if (!synchronized || rename(partial.c_str(), path.c_str()) != 0) {
        unlink(partial.c_str());
        return CoreError(11, @"The suspend state could not be saved.");
    }
    return nil;
}

static NSError *LoadSuspendState(const std::string &path) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return CoreError(12, @"The saved suspend state was not found.");
    struct stat info = {};
    if (fstat(fd, &info) != 0 || info.st_size <= 0) {
        close(fd);
        return CoreError(12, @"The saved suspend state is invalid.");
    }
    const size_t size = static_cast<size_t>(info.st_size);
    void *mapping = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mapping == MAP_FAILED) {
        close(fd);
        return CoreError(12, @"The saved suspend state could not be read.");
    }
    const bool loaded = retro_unserialize(mapping, size);
    munmap(mapping, size);
    close(fd);
    return loaded ? nil : CoreError(13, @"DOSBox Pure rejected the saved suspend state.");
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
    std::atomic_bool _guestShutdownRequested;
    std::atomic_bool _resetRequested;
    std::atomic_int _mouseX;
    std::atomic_int _mouseY;
    std::atomic_bool _leftButton;
    std::atomic_bool _rightButton;
    std::atomic_int _wheelUp;
    std::atomic_int _wheelDown;

    std::mutex _videoMutex;
    std::vector<uint8_t> _video;
    NSInteger _videoWidth;
    NSInteger _videoHeight;
    NSInteger _videoPitch;
    double _videoAspectRatio;
    uint64_t _videoGeneration;

    std::mutex _audioMutex;
    std::deque<int16_t> _audio;

    std::mutex _operationMutex;
    std::deque<Operation> _operations;

    std::mutex _inputMutex;
    std::deque<KeyEvent> _keyEvents;

    std::string _saveDirectory;
    std::string _systemDirectory;
    std::string _contentPath;
    std::unordered_map<std::string, std::string> _options;
}
- (void)runDiskPath:(NSString *)path CDPath:(NSString * _Nullable)CDPath completion:(Win95Completion)completion;
- (void)processOperations;
- (void)processKeyEvents;
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
        _guestShutdownRequested = false;
        _resetRequested = false;
        _mouseX = _mouseY = 0;
        _leftButton = _rightButton = false;
        _wheelUp = _wheelDown = 0;
        _videoWidth = _videoHeight = _videoPitch = 0;
        _videoAspectRatio = 4.0 / 3.0;
        _videoGeneration = 0;
        _saveDirectory = saveDirectory.fileSystemRepresentation;
        _systemDirectory = systemDirectory.fileSystemRepresentation;
        _options = {
            {"dosbox_pure_force60fps", "true"},
            {"dosbox_pure_savestate", "on"},
            {"dosbox_pure_strict_mode", "false"},
            {"dosbox_pure_conf", "false"},
            {"dosbox_pure_menu_time", "0"},
            {"dosbox_pure_mouse_input", "true"},
            {"dosbox_pure_mouse_speed_factor", "1.0"},
            {"dosbox_pure_cycles", "200000"},
            {"dosbox_pure_cycles_max", "200000"},
            {"dosbox_pure_machine", "svga"},
            {"dosbox_pure_svga", "svga_s3"},
            {"dosbox_pure_svgamem", "2"},
            {"dosbox_pure_voodoo", "off"},
            {"dosbox_pure_voodoo_perf", "0"},
            {"dosbox_pure_memory_size", "128"},
            {"dosbox_pure_cpu_type", "pentium_mmx"},
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

- (void)startWithDiskURL:(NSURL *)diskURL CDURL:(NSURL *)CDURL completion:(Win95Completion)completion {
    if (_running.exchange(true)) {
        [self finishOperation:completion error:CoreError(1, @"The virtual machine is already running.")];
        return;
    }
    _stopRequested = false;
    _guestShutdownRequested = false;
    _paused = false;
    {
        std::lock_guard<std::mutex> lock(_inputMutex);
        _keyEvents.clear();
        _mouseX = _mouseY = 0;
        _leftButton = _rightButton = false;
        _wheelUp = _wheelDown = 0;
    }
    NSString *path = diskURL.path;
    NSString *CDPath = CDURL.path;
    dispatch_async(_emulationQueue, ^{ [self runDiskPath:path CDPath:CDPath completion:completion]; });
}

- (void)runDiskPath:(NSString *)path CDPath:(NSString *)CDPath completion:(Win95Completion)completion {
    @autoreleasepool {
        gBridge = self;
        gKeyboardCallback = nullptr;
        _contentPath = path.fileSystemRepresentation;
        _contentPath += "#I*SVGA (Super Video Graphics Array)";
        dbp_win95_set_initial_cd(CDPath ? CDPath.fileSystemRepresentation : nullptr);

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
            gBridge = nil;
            _running = false;
            [self finishOperation:completion error:CoreError(2, @"DOSBox Pure could not load the disk image.")];
            return;
        }

        retro_system_av_info av = {};
        retro_get_system_av_info(&av);
        {
            std::lock_guard<std::mutex> lock(_videoMutex);
            _videoAspectRatio = av.geometry.aspect_ratio > 0.0f
                ? av.geometry.aspect_ratio
                : (av.geometry.base_height ? (double)av.geometry.base_width / av.geometry.base_height : 4.0 / 3.0);
        }
        [self finishOperation:completion error:nil];
        if (self.statusHandler) dispatch_async(dispatch_get_main_queue(), ^{ self.statusHandler(@"Running"); });

        using Clock = std::chrono::steady_clock;
        auto deadline = Clock::now();
        while (!_stopRequested.load()) {
            @autoreleasepool {
                [self processOperations];
                if (_resetRequested.exchange(false)) retro_reset();
                if (!_paused.load()) {
                    [self processKeyEvents];
                    retro_run();
                    if (dbp_win95_guest_shutdown()) {
                        _guestShutdownRequested = true;
                        _stopRequested = true;
                    }
                }
                else std::this_thread::sleep_for(std::chrono::milliseconds(8));
            }
            deadline += std::chrono::microseconds(16667);
            auto now = Clock::now();
            if (deadline > now) std::this_thread::sleep_until(deadline);
            else deadline = now;
        }

        // Finish requests that raced with a stop (notably the last automatic
        // suspend write) while the libretro instance is still valid.
        [self processOperations];
        dbp_win95_flush_disk();
        retro_unload_game();
        retro_deinit();
        gKeyboardCallback = nullptr;
        gBridge = nil;
        _running = false;
        _paused = false;
        const bool guestShutdown = _guestShutdownRequested.load();
        if (self.statusHandler) dispatch_async(dispatch_get_main_queue(), ^{
            self.statusHandler(guestShutdown ? @"Shutdown" : @"Stopped");
        });
    }
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    if (!_running.load()) { if (completion) completion(); return; }
    _stopRequested = true;
    dispatch_async(_emulationQueue, ^{ if (completion) dispatch_async(dispatch_get_main_queue(), completion); });
}

- (void)setEmulationPaused:(BOOL)paused {
    const bool changed = _paused.exchange(paused) != paused;
    if (paused) {
        {
            std::lock_guard<std::mutex> lock(_inputMutex);
            _keyEvents.clear();
            _mouseX = _mouseY = 0;
            _leftButton = _rightButton = false;
            _wheelUp = _wheelDown = 0;
        }
        if (changed && _running.load()) {
            [self enqueueOperation:Operation{PendingOperation::ReleaseInput, {}, nil}];
            [self flushDisk];
        }
    }
    if (self.statusHandler) dispatch_async(dispatch_get_main_queue(), ^{ self.statusHandler(paused ? @"Paused" : @"Running"); });
}

- (void)reset {
    [self flushDisk];
    _resetRequested = true;
}

- (void)enqueueOperation:(Operation)operation {
    std::lock_guard<std::mutex> lock(_operationMutex);
    _operations.push_back(std::move(operation));
}

- (void)flushDisk {
    if (_running.load()) [self enqueueOperation:Operation{PendingOperation::Flush, {}, nil}];
}

- (void)flushDiskWithCompletion:(Win95Completion)completion {
    if (!_running.load()) { [self finishOperation:completion error:CoreError(8, @"The virtual machine is not running.")]; return; }
    [self enqueueOperation:Operation{PendingOperation::Flush, {}, [completion copy]}];
}

- (void)saveSuspendStateToURL:(NSURL *)url completion:(Win95Completion)completion {
    if (!_running.load()) { [self finishOperation:completion error:CoreError(8, @"The virtual machine is not running.")]; return; }
    [self enqueueOperation:Operation{PendingOperation::SaveSuspend, url.fileSystemRepresentation, [completion copy]}];
}

- (void)loadSuspendStateFromURL:(NSURL *)url completion:(Win95Completion)completion {
    if (!_running.load()) { [self finishOperation:completion error:CoreError(8, @"The virtual machine is not running.")]; return; }
    // Freeze before loading so the restored guest cannot advance while the
    // completion travels back to UIKit.
    [self setEmulationPaused:YES];
    [self enqueueOperation:Operation{PendingOperation::LoadSuspend, url.fileSystemRepresentation, [completion copy]}];
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
            case PendingOperation::SaveSuspend:
                dbp_win95_flush_disk();
                error = SaveSuspendState(operation.path);
                break;
            case PendingOperation::LoadSuspend:
                error = LoadSuspendState(operation.path);
                break;
            case PendingOperation::ReleaseInput:
                dbp_win95_release_input();
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
    frame.aspectRatio = _videoAspectRatio;
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
    std::lock_guard<std::mutex> lock(_inputMutex);
    if (!_running.load() || _paused.load()) return;
    _keyEvents.push_back(KeyEvent{keyCode, static_cast<bool>(pressed)});
}

- (void)processKeyEvents {
    std::deque<KeyEvent> events;
    {
        std::lock_guard<std::mutex> lock(_inputMutex);
        events.swap(_keyEvents);
    }
    retro_keyboard_event_t callback = gKeyboardCallback.load();
    if (!callback) return;
    for (const KeyEvent &event : events) callback(event.pressed, event.keyCode, 0, 0);
}

- (void)addMouseDeltaX:(NSInteger)deltaX deltaY:(NSInteger)deltaY {
    std::lock_guard<std::mutex> lock(_inputMutex);
    if (!_running.load() || _paused.load()) return;
    _mouseX.fetch_add((int)MAX(-32767, MIN(32767, deltaX)));
    _mouseY.fetch_add((int)MAX(-32767, MIN(32767, deltaY)));
}

- (void)addMouseWheelDelta:(NSInteger)delta {
    std::lock_guard<std::mutex> lock(_inputMutex);
    if (!_running.load() || _paused.load()) return;
    const int steps = (int)MAX(-32, MIN(32, delta));
    if (steps < 0) _wheelUp.fetch_add(-steps);
    else if (steps > 0) _wheelDown.fetch_add(steps);
}

- (void)setLeftMouseButton:(BOOL)pressed {
    std::lock_guard<std::mutex> lock(_inputMutex);
    _leftButton = (!_paused.load() && pressed);
}

- (void)setRightMouseButton:(BOOL)pressed {
    std::lock_guard<std::mutex> lock(_inputMutex);
    _rightButton = (!_paused.load() && pressed);
}

- (int16_t)inputStatePort:(unsigned)port device:(unsigned)device index:(unsigned)index identifier:(unsigned)identifier {
    if (_paused.load() || port || device != RETRO_DEVICE_MOUSE) return 0;
    switch (identifier) {
        case RETRO_DEVICE_ID_MOUSE_X: return (int16_t)MAX(-32767, MIN(32767, _mouseX.exchange(0)));
        case RETRO_DEVICE_ID_MOUSE_Y: return (int16_t)MAX(-32767, MIN(32767, _mouseY.exchange(0)));
        case RETRO_DEVICE_ID_MOUSE_LEFT: return _leftButton.load() ? 1 : 0;
        case RETRO_DEVICE_ID_MOUSE_RIGHT: return _rightButton.load() ? 1 : 0;
        case RETRO_DEVICE_ID_MOUSE_WHEELUP: {
            int value = _wheelUp.load();
            while (value > 0 && !_wheelUp.compare_exchange_weak(value, value - 1)) {}
            return value > 0 ? 1 : 0;
        }
        case RETRO_DEVICE_ID_MOUSE_WHEELDOWN: {
            int value = _wheelDown.load();
            while (value > 0 && !_wheelDown.compare_exchange_weak(value, value - 1)) {}
            return value > 0 ? 1 : 0;
        }
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
            return true;
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
        case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
        case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
            return true;
        case RETRO_ENVIRONMENT_SET_GEOMETRY: {
            const retro_game_geometry *geometry = static_cast<const retro_game_geometry *>(data);
            std::lock_guard<std::mutex> lock(_videoMutex);
            _videoAspectRatio = geometry->aspect_ratio > 0.0f
                ? geometry->aspect_ratio
                : (geometry->base_height ? (double)geometry->base_width / geometry->base_height : _videoAspectRatio);
            return true;
        }
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
            const retro_system_av_info *info = static_cast<const retro_system_av_info *>(data);
            const retro_game_geometry &geometry = info->geometry;
            std::lock_guard<std::mutex> lock(_videoMutex);
            _videoAspectRatio = geometry.aspect_ratio > 0.0f
                ? geometry.aspect_ratio
                : (geometry.base_height ? (double)geometry.base_width / geometry.base_height : _videoAspectRatio);
            return true;
        }
        case RETRO_ENVIRONMENT_SET_MESSAGE: {
            retro_message *message = static_cast<retro_message *>(data);
            if (self.statusHandler && message->msg) {
                NSString *text = [NSString stringWithUTF8String:message->msg];
                dispatch_async(dispatch_get_main_queue(), ^{ self.statusHandler(text); });
            }
            return true;
        }
        case RETRO_ENVIRONMENT_SHUTDOWN:
            _guestShutdownRequested = true;
            _stopRequested = true;
            return true;
        default:
            return false;
    }
}

@end
