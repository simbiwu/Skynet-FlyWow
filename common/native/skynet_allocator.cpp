// 职责：让 FlyWow Native 内的 C++ 动态分配统一使用 Skynet 宿主导出的 jemalloc。
// 边界：只供由 Skynet 加载的 Native 共享库链接；不替换 malloc/free，也不拥有独立 jemalloc。
#include <cstddef>
#include <cstdint>
#include <limits>
#include <new>

extern "C" void *je_malloc(std::size_t size);
extern "C" void je_free(void *memory);

namespace
{
void *allocate(std::size_t size)
{
    if (void *memory = je_malloc(size == 0 ? 1 : size)) return memory;
    throw std::bad_alloc();
}

void *allocateAligned(std::size_t size, std::size_t alignment)
{
    const std::size_t payload = size == 0 ? 1 : size;
    if (payload > std::numeric_limits<std::size_t>::max() - alignment - sizeof(void *)) throw std::bad_alloc();
    void *base = je_malloc(payload + alignment - 1 + sizeof(void *));
    if (base == nullptr) throw std::bad_alloc();
    const auto start = reinterpret_cast<std::uintptr_t>(base) + sizeof(void *);
    const auto address = (start + alignment - 1) & ~(static_cast<std::uintptr_t>(alignment) - 1);
    auto *result = reinterpret_cast<void *>(address);
    reinterpret_cast<void **>(result)[-1] = base;
    return result;
}

void deallocateAligned(void *memory) noexcept
{
    if (memory != nullptr) je_free(reinterpret_cast<void **>(memory)[-1]);
}
}

#define FLYWOW_ALLOCATOR_API
FLYWOW_ALLOCATOR_API void *operator new(std::size_t size) { return allocate(size); }
FLYWOW_ALLOCATOR_API void *operator new[](std::size_t size) { return allocate(size); }
FLYWOW_ALLOCATOR_API void operator delete(void *memory) noexcept { je_free(memory); }
FLYWOW_ALLOCATOR_API void operator delete[](void *memory) noexcept { je_free(memory); }
FLYWOW_ALLOCATOR_API void operator delete(void *memory, std::size_t) noexcept { je_free(memory); }
FLYWOW_ALLOCATOR_API void operator delete[](void *memory, std::size_t) noexcept { je_free(memory); }
FLYWOW_ALLOCATOR_API void *operator new(std::size_t size, const std::nothrow_t &) noexcept
{ try { return allocate(size); } catch (...) { return nullptr; } }
FLYWOW_ALLOCATOR_API void *operator new[](std::size_t size, const std::nothrow_t &) noexcept
{ try { return allocate(size); } catch (...) { return nullptr; } }
FLYWOW_ALLOCATOR_API void operator delete(void *memory, const std::nothrow_t &) noexcept { je_free(memory); }
FLYWOW_ALLOCATOR_API void operator delete[](void *memory, const std::nothrow_t &) noexcept { je_free(memory); }
FLYWOW_ALLOCATOR_API void *operator new(std::size_t size, std::align_val_t alignment)
{ return allocateAligned(size, static_cast<std::size_t>(alignment)); }
FLYWOW_ALLOCATOR_API void *operator new[](std::size_t size, std::align_val_t alignment)
{ return allocateAligned(size, static_cast<std::size_t>(alignment)); }
FLYWOW_ALLOCATOR_API void operator delete(void *memory, std::align_val_t) noexcept { deallocateAligned(memory); }
FLYWOW_ALLOCATOR_API void operator delete[](void *memory, std::align_val_t) noexcept { deallocateAligned(memory); }
FLYWOW_ALLOCATOR_API void operator delete(void *memory, std::size_t, std::align_val_t) noexcept { deallocateAligned(memory); }
FLYWOW_ALLOCATOR_API void operator delete[](void *memory, std::size_t, std::align_val_t) noexcept { deallocateAligned(memory); }
FLYWOW_ALLOCATOR_API void *operator new(std::size_t size, std::align_val_t alignment, const std::nothrow_t &) noexcept
{ try { return allocateAligned(size, static_cast<std::size_t>(alignment)); } catch (...) { return nullptr; } }
FLYWOW_ALLOCATOR_API void *operator new[](std::size_t size, std::align_val_t alignment, const std::nothrow_t &) noexcept
{ try { return allocateAligned(size, static_cast<std::size_t>(alignment)); } catch (...) { return nullptr; } }
FLYWOW_ALLOCATOR_API void operator delete(void *memory, std::align_val_t, const std::nothrow_t &) noexcept
{ deallocateAligned(memory); }
FLYWOW_ALLOCATOR_API void operator delete[](void *memory, std::align_val_t, const std::nothrow_t &) noexcept
{ deallocateAligned(memory); }
