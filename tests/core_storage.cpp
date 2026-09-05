// Synthetic media only: no Windows files or third-party disk images required.
#include "dosbox.h"
#include "bios_disk.h"
#include "../src/dos/drives.h"
#include "../src/dos/cdrom.h"
#include "libretro.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <sys/resource.h>
#include <unistd.h>

extern "C" bool dbp_win95_disk_ready();
extern "C" int dbp_win95_change_cd(const char*);
extern "C" void dbp_win95_flush_disk();
extern "C" void dbp_win95_set_nat_active(bool);
static std::string directory;
static retro_netpacket_callback netpacket = {};
static void networkSend(int, const void*, size_t, uint16_t) {}
static void networkReceivePoll() {}
static void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static void be(std::vector<unsigned char>& v, size_t offset, uint64_t value, size_t bytes) {
    while (bytes) { v[offset + --bytes] = value & 255; value >>= 8; }
}
static void le(std::vector<unsigned char>& v, size_t offset, uint32_t value, size_t bytes) {
    for (size_t i = 0; i < bytes; ++i) { v[offset + i] = value & 255; value >>= 8; }
}
static void writeFile(const std::string& path, const std::vector<unsigned char>& data) {
    FILE* f = fopen(path.c_str(), "wb"); check(f != nullptr, "fixture open");
    check(fwrite(data.data(), 1, data.size(), f) == data.size(), "fixture write"); fclose(f);
}
static std::vector<unsigned char> readFile(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb"); check(f != nullptr, "read file");
    fseek(f, 0, SEEK_END); const long size = ftell(f); rewind(f);
    std::vector<unsigned char> data(size); check(fread(data.data(), 1, data.size(), f) == data.size(), "read bytes"); fclose(f); return data;
}
static std::unique_ptr<imageDisk> disk(const std::string& path) {
    rawFile* file = rawFile::TryOpen(path.c_str()); check(file != nullptr, "rawFile open");
    std::unique_ptr<imageDisk> result(new imageDisk(file, path.c_str(), 16384, true));
    result->Set_GeometryForHardDisk(); return result;
}
static void overlayRecord(std::vector<unsigned char>& bytes, uint32_t sector, unsigned char value, size_t size = 512) {
    for (int i = 0; i < 4; ++i) bytes.push_back((sector >> (8 * i)) & 255);
    bytes.insert(bytes.end(), size, value);
}
static bool environment(unsigned cmd, void* data) {
    if (cmd == RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY || cmd == RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY) {
        *static_cast<const char**>(data) = directory.c_str(); return true;
    }
    if (cmd == RETRO_ENVIRONMENT_GET_VARIABLE) {
        retro_variable* v = static_cast<retro_variable*>(data);
        const std::pair<const char*, const char*> options[] = {
            {"dosbox_pure_cpu_core", "normal"}, {"dosbox_pure_cpu_type", "pentium_slow"},
            {"dosbox_pure_cycles", "10000"}, {"dosbox_pure_memory_size", "128"},
            {"dosbox_pure_force60fps", "true"}, {"dosbox_pure_menu_time", "0"},
            {"dosbox_pure_conf", "false"}, {"dosbox_pure_voodoo", "off"},
            {"dosbox_pure_savestate", "on"}
        };
        for (auto& option : options) if (!strcmp(v->key, option.first)) { v->value = option.second; return true; }
        return false;
    }
    if (cmd == RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE) { *static_cast<bool*>(data) = false; return true; }
    if (cmd == RETRO_ENVIRONMENT_SET_NETPACKET_INTERFACE) {
        netpacket = *static_cast<const retro_netpacket_callback*>(data); return true;
    }
    return cmd == RETRO_ENVIRONMENT_SET_PIXEL_FORMAT || cmd == RETRO_ENVIRONMENT_SET_GEOMETRY || cmd == RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO;
}
static void video(const void*, unsigned, unsigned, size_t) {}
static size_t audio(const int16_t*, size_t frames) { return frames; }
static void poll() {}
static int16_t input(unsigned, unsigned, unsigned, unsigned) { return 0; }

int main(int argc, char** argv) {
    try {
        check(argc == 2, "provide a temporary fixture directory"); directory = argv[1];
        std::vector<unsigned char> raw(16 * 1024 * 1024);
        raw[0] = 0xEB; raw[1] = 0xFE; raw[510] = 0x55; raw[511] = 0xAA; // boot: jmp $
        std::fill(raw.begin() + 100 * 512, raw.begin() + 101 * 512, 0x77);
        writeFile(directory + "/base.img", raw);

        // Dynamic VHD with one allocated 2 MiB block, like qemu-img -O vpc.
        std::vector<unsigned char> footer(512), sparse(1024);
        memcpy(footer.data(), "conectix", 8); be(footer, 8, 2, 4); be(footer, 12, 0x10000, 4);
        be(footer, 16, 512, 8); be(footer, 40, raw.size(), 8); be(footer, 48, raw.size(), 8);
        be(footer, 60, 3, 4); uint32_t sum = 0; for (auto byte : footer) sum += byte; be(footer, 64, ~sum, 4);
        memcpy(sparse.data(), "cxsparse", 8); be(sparse, 8, UINT64_MAX, 8); be(sparse, 16, 1536, 8);
        be(sparse, 24, 0x10000, 4); be(sparse, 28, 8, 4); be(sparse, 32, 2 * 1024 * 1024, 4);
        sum = 0; for (auto byte : sparse) sum += byte; be(sparse, 36, ~sum, 4);
        std::vector<unsigned char> vhd = footer; vhd.insert(vhd.end(), sparse.begin(), sparse.end());
        vhd.resize(2048, 0xFF); be(vhd, 1536, 4, 4); vhd.resize(2560, 0xFF);
        vhd.insert(vhd.end(), raw.begin(), raw.begin() + 2 * 1024 * 1024); vhd.insert(vhd.end(), footer.begin(), footer.end());
        writeFile(directory + "/base.vhd", vhd);

        for (const char* ext : {"img", "vhd"}) {
            const std::string path = directory + "/base." + ext;
            const std::string save = directory + "/overlay-" + ext + ".sav";
            std::array<unsigned char, 512> sector, expected; expected.fill(0x77);
            {
                auto d = disk(path); d->SetDifferencingDisk(save.c_str());
                check(!d->Read_AbsoluteSector(100, sector.data()) && sector == expected, "base logical sector");
                check(!d->Write_AbsoluteSector(100, expected.data()), "write identical logical sector");
                check(access(save.c_str(), F_OK) != 0, "unchanged VHD sector must not create overlay");
                expected.fill(0xA3); check(!d->Write_AbsoluteSector(101, expected.data()), "write changed sector");
                check(!d->Write_AbsoluteSector(32767, expected.data()), "write LBA sector beyond rounded CHS");
                d->FlushDifferencingDisk();
            }
            {
                auto d = disk(path); d->SetDifferencingDisk(save.c_str());
                check(!d->Read_AbsoluteSector(101, sector.data()) && sector == expected, "overlay survives reopen");
                check(!d->Read_AbsoluteSector(32767, sector.data()) && sector == expected, "tail LBA survives reopen");
                expected.fill(0x77); check(!d->Read_AbsoluteSector(100, sector.data()) && sector == expected, "base survives reopen");
            }
            std::vector<unsigned char> damaged = {'F','F','D','D',1};
            overlayRecord(damaged, 101, 0xA3); overlayRecord(damaged, 0xFFFFFFFE, 0xCC);
            overlayRecord(damaged, 102, 0xB4); overlayRecord(damaged, 103, 0xDD, 17);
            writeFile(save, damaged);
            for (int reopen = 0; reopen < 3; ++reopen) {
                auto d = disk(path); d->SetDifferencingDisk(save.c_str());
                expected.fill(0xA3); check(!d->Read_AbsoluteSector(101, sector.data()) && sector == expected, "valid record before invalid sector");
                expected.fill(0xB4); check(!d->Read_AbsoluteSector(102, sector.data()) && sector == expected, "valid record after invalid sector");
                expected.fill(0xE5); check(!d->Write_AbsoluteSector(104, expected.data()), "write after recovery"); d->FlushDifferencingDisk();
            }
            bool foundBackup = false; DIR* dir = opendir(directory.c_str()); check(dir != nullptr, "backup directory");
            while (dirent* entry = readdir(dir)) {
                const std::string candidate = directory + "/" + entry->d_name;
                if (candidate.find(save + ".recovery-") != 0) continue;
                check(readFile(candidate) == damaged, "recovery backup preserves all original bytes"); foundBackup = true;
            }
            closedir(dir); check(foundBackup, "interrupted write must have a backup");
            check(readFile(path) == (std::string(ext) == "img" ? raw : vhd), "base image stays byte-for-byte unchanged");
        }

        // Exercise the FAT16 ownership path used by early Windows 95 images.
        std::vector<unsigned char> fat = raw;
        std::fill(fat.begin() + 100 * 512, fat.begin() + 101 * 512, 0);
        fat[446] = 0x80; fat[450] = 0x06; le(fat, 454, 63, 4); le(fat, 458, 32705, 4);
        const size_t bpb = 63 * 512;
        fat[bpb] = 0xEB; fat[bpb + 1] = 0xFE; le(fat, bpb + 11, 512, 2);
        fat[bpb + 13] = 2; le(fat, bpb + 14, 1, 2); fat[bpb + 16] = 2;
        le(fat, bpb + 17, 512, 2); le(fat, bpb + 19, 32705, 2); fat[bpb + 21] = 0xF8;
        le(fat, bpb + 22, 64, 2); le(fat, bpb + 24, 63, 2); le(fat, bpb + 26, 16, 2);
        le(fat, bpb + 28, 63, 4); fat[bpb + 510] = 0x55; fat[bpb + 511] = 0xAA;
        le(fat, 64 * 512, 0xFFFFFFF8, 4); le(fat, 128 * 512, 0xFFFFFFF8, 4);
        writeFile(directory + "/boot-fat.img", fat);

        retro_set_environment(environment); retro_set_video_refresh(video); retro_set_audio_sample_batch(audio);
        retro_set_input_poll(poll); retro_set_input_state(input); retro_init();
        check(netpacket.start && netpacket.receive && netpacket.stop && netpacket.poll, "netpacket callbacks registered");
        dbp_win95_set_nat_active(true);
        netpacket.start(0, networkSend, networkReceivePoll);
        const std::string boot = directory + "/boot-fat.img#I*SVGA (Super Video Graphics Array)";
        retro_game_info info = {}; info.path = boot.c_str(); check(retro_load_game(&info), "load boot fixture");
        for (int i = 0; i < 300 && !dbp_win95_disk_ready(); ++i) retro_run();
        check(dbp_win95_disk_ready(), "BIOS/IDE ready");
        std::vector<unsigned char> iso(64 * 2048);
        memcpy(iso.data() + 16 * 2048, "\1CD001\1", 7);
        std::fill(iso.begin() + 20 * 2048, iso.begin() + 21 * 2048, 0x5A);
        writeFile(directory + "/disc.iso", iso);
        writeFile(directory + "/invalid.iso", std::vector<unsigned char>(1200 * 1024));
        FILE* largeISO = fopen((directory + "/disc.iso").c_str(), "rb+"); check(largeISO != nullptr, "large ISO open");
        check(ftruncate(fileno(largeISO), 512 * 1024 * 1024) == 0, "sparse 512 MiB ISO"); fclose(largeISO);
        imageDisk* bootDisk = imageDiskList[2];
        rusage beforeCD = {}; getrusage(RUSAGE_SELF, &beforeCD);
        for (int i = 0; i < 12; ++i) {
            check(dbp_win95_change_cd((directory + "/disc.iso").c_str()) == 1, "live CD insert");
            auto cd = CDROM_Interface_Image::images[25]; check(cd != nullptr, "CD owned by IDE frontend");
            std::array<unsigned char, 2048> data; check(cd->ReadSector(data.data(), false, 20), "CD sector read");
            for (auto byte : data) check(byte == 0x5A, "CD content");
            check(dbp_win95_change_cd((directory + "/absent.iso").c_str()) == 0, "invalid ISO rejected");
            check(CDROM_Interface_Image::images[25] == cd, "failed replacement preserves current media");
            check(dbp_win95_change_cd((directory + "/invalid.iso").c_str()) == 0, "malformed small ISO rejected");
            check(CDROM_Interface_Image::images[25] == cd, "malformed replacement preserves media");
            check(imageDiskList[2] == bootDisk, "CD operation must not replace HDD");
            check(dbp_win95_change_cd(nullptr) == 1, "live eject"); retro_run();
        }
        rusage afterCD = {}; getrusage(RUSAGE_SELF, &afterCD);
#if defined(__linux__)
        check(afterCD.ru_maxrss - beforeCD.ru_maxrss < 64 * 1024, "512 MiB ISO must not be loaded wholesale into RAM");
#endif
        check(dbp_win95_change_cd((directory + "/disc.iso").c_str()) == 1, "insert before reset");
        const size_t stateSize = retro_serialize_size(); check(stateSize != 0, "suspend size");
        std::vector<unsigned char> snapshot(stateSize);
        check(retro_serialize(snapshot.data(), snapshot.size()), "save with CD mounted");
        retro_reset();
        for (int i = 0; i < 60; ++i) retro_run();
        check(dbp_win95_disk_ready() && CDROM_Interface_Image::images[25], "CD reattached after reset");
        check(retro_unserialize(snapshot.data(), snapshot.size()), "restore with CD mounted");
        std::array<unsigned char, 2048> restoredCD;
        check(CDROM_Interface_Image::images[25]->ReadSector(restoredCD.data(), false, 20) && restoredCD[0] == 0x5A, "CD readable after suspend restore");
        netpacket.poll(); netpacket.stop(); dbp_win95_set_nat_active(false);
        dbp_win95_flush_disk(); retro_unload_game(); retro_deinit();
        puts("PASS: netpacket registration, raw/VHD overlays, damaged-save recovery, repeated live CD insert/read/eject and failed replacement");
        return 0;
    } catch (const std::exception& e) { fprintf(stderr, "FAIL: %s\n", e.what()); std::_Exit(1); }
}
