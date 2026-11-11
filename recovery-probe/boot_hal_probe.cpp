#include <aidl/android/hardware/boot/IBootControl.h>
#include <android/binder_manager.h>
#include <android/binder_auto_utils.h>
#include <cstdio>

// Deliberately expose no mutating operations and never wait for a missing service.
int main() {
    constexpr const char* name = "android.hardware.boot.IBootControl/default";
    ndk::SpAIBinder binder(AServiceManager_checkService(name));
    if (!binder.get()) {
        std::fprintf(stderr, "Boot HAL not found or lookup denied\n");
        return 1;
    }
    std::puts("Boot HAL registered");
    if (AIBinder_ping(binder.get()) != STATUS_OK) {
        std::fprintf(stderr, "Binder ping failed\n");
        return 2;
    }
    std::puts("Binder ping OK");
    auto hal = aidl::android::hardware::boot::IBootControl::fromBinder(binder);
    if (!hal) return 3;
    int32_t count = -1, current = -1;
    auto status = hal->getNumberSlots(&count);
    if (!status.isOk()) {
        std::fprintf(stderr, "getNumberSlots failed: %s\n", status.getDescription().c_str());
        return 4;
    }
    status = hal->getCurrentSlot(&current);
    if (!status.isOk()) {
        std::fprintf(stderr, "getCurrentSlot failed: %s\n", status.getDescription().c_str());
        return 5;
    }
    std::printf("Number of slots: %d\nCurrent slot: %d\n", count, current);
    if (count <= 0 || count > 32 || current < 0 || current >= count) return 6;
    std::string suffix;
    status = hal->getSuffix(current, &suffix);
    if (!status.isOk()) {
        std::fprintf(stderr, "getSuffix failed: %s\n", status.getDescription().c_str());
        return 7;
    }
    std::printf("Current slot suffix: %s\n", suffix.c_str());
    return 0;
}
