#pragma once

#import <Metal/Metal.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <utility>
#include <vector>

namespace metalcadence {

// These counters describe the output/intermediate texture pools, not every
// allocation made by MetalFX, VideoToolbox, CAMetalLayer, or the OS.
struct TextureBudget {
    explicit TextureBudget(std::size_t limit) : limitBytes(limit) {
    }

    bool reserve(std::size_t bytes) {
        std::scoped_lock lock(mutex);
        if (bytes > limitBytes || activeBytes + cachedBytes > limitBytes - bytes) {
            return false;
        }
        activeBytes += bytes;
        peakBytes = std::max(peakBytes, activeBytes + cachedBytes);
        return true;
    }

    void checkout(std::size_t bytes) {
        std::scoped_lock lock(mutex);
        cachedBytes -= bytes;
        activeBytes += bytes;
    }

    void recycle(std::size_t bytes) {
        std::scoped_lock lock(mutex);
        activeBytes -= bytes;
        cachedBytes += bytes;
    }

    void releaseActive(std::size_t bytes) {
        std::scoped_lock lock(mutex);
        activeBytes -= bytes;
    }

    void releaseCached(std::size_t bytes) {
        std::scoped_lock lock(mutex);
        cachedBytes -= bytes;
    }

    std::size_t limitBytes;
    std::mutex mutex;
    std::size_t activeBytes = 0;
    std::size_t cachedBytes = 0;
    std::size_t peakBytes = 0;
};

// Scoped lifetime for a cached Objective-C Metal resource. An ARC strong
// reference owns each item while it resides in this movable C++20 vector.
struct CachedTexture {
    __strong id<MTLTexture> resource;
    std::size_t byteCost;

    CachedTexture(id<MTLTexture> value, std::size_t cost) : resource(value), byteCost(cost) {
    }

    CachedTexture(const CachedTexture &) = delete;
    CachedTexture &operator=(const CachedTexture &) = delete;
    CachedTexture(CachedTexture &&) noexcept = default;
    CachedTexture &operator=(CachedTexture &&) noexcept = default;
};

class TexturePool final {
  public:
    TexturePool(id<MTLDevice> device,
                MTLTextureDescriptor *descriptor,
                std::shared_ptr<TextureBudget> budget,
                std::size_t cacheCapacity)
        : device_(device), descriptor_([descriptor copy]), budget_(std::move(budget)),
          cacheCapacity_(cacheCapacity) {
        // Heap sizing provides an allocation estimate even though these
        // resources are ordinary private textures, not Metal heap members.
        MTLSizeAndAlign allocation = [device_ heapTextureSizeAndAlignWithDescriptor:descriptor_];
        byteCost_ = allocation.size;
        if (byteCost_ == 0) {
            byteCost_ = static_cast<std::size_t>(descriptor_.width) *
                        static_cast<std::size_t>(descriptor_.height) * 4;
        }
        cache_.reserve(cacheCapacity_);
    }

    ~TexturePool() {
        std::scoped_lock lock(mutex_);
        for (const auto &entry : cache_) {
            budget_->releaseCached(entry.byteCost);
        }
    }

    TexturePool(const TexturePool &) = delete;
    TexturePool &operator=(const TexturePool &) = delete;

    id<MTLTexture> acquire() {
        std::scoped_lock lock(mutex_);
        if (!cache_.empty()) {
            CachedTexture resource = std::move(cache_.back());
            cache_.pop_back();
            budget_->checkout(resource.byteCost);
            id<MTLTexture> texture = resource.resource;
            outstanding_[(__bridge void *)texture] = resource.byteCost;
            reuses_++;
            return texture;
        }

        if (!budget_->reserve(byteCost_)) {
            denied_++;
            return nil;
        }

        id<MTLTexture> texture = [device_ newTextureWithDescriptor:descriptor_];
        if (!texture) {
            budget_->releaseActive(byteCost_);
            denied_++;
            return nil;
        }

        outstanding_[(__bridge void *)texture] = byteCost_;
        allocations_++;
        return texture;
    }

    void release(id<MTLTexture> texture) {
        if (!texture) {
            return;
        }

        std::scoped_lock lock(mutex_);
        auto found = outstanding_.find((__bridge void *)texture);
        if (found == outstanding_.end()) {
            // Refuse duplicate or foreign returns; do not corrupt the budget.
            return;
        }
        std::size_t bytes = found->second;
        outstanding_.erase(found);

        if (cache_.size() < cacheCapacity_) {
            cache_.emplace_back(texture, bytes);
            budget_->recycle(bytes);
        } else {
            budget_->releaseActive(bytes);
            evictions_++;
        }
    }

    void prewarm(std::size_t amount) {
        std::vector<id<MTLTexture>> outstanding;
        outstanding.reserve(amount);
        for (std::size_t i = 0; i < amount; ++i) {
            id<MTLTexture> texture = acquire();
            if (!texture) {
                break;
            }
            outstanding.push_back(texture);
        }
        for (id<MTLTexture> texture : outstanding) {
            release(texture);
        }
    }

    std::uint64_t allocations() const {
        return allocations_.load();
    }
    std::uint64_t reuses() const {
        return reuses_.load();
    }
    std::uint64_t evictions() const {
        return evictions_.load();
    }
    std::uint64_t denied() const {
        return denied_.load();
    }
    std::size_t byteCost() const {
        return byteCost_;
    }

    std::size_t cachedCount() const {
        std::scoped_lock lock(mutex_);
        return cache_.size();
    }

  private:
    __strong id<MTLDevice> device_;
    __strong MTLTextureDescriptor *descriptor_;
    std::shared_ptr<TextureBudget> budget_;
    const std::size_t cacheCapacity_;
    std::size_t byteCost_ = 0;

    mutable std::mutex mutex_;
    std::vector<CachedTexture> cache_;
    std::unordered_map<void *, std::size_t> outstanding_;

    std::atomic<std::uint64_t> allocations_ = 0;
    std::atomic<std::uint64_t> reuses_ = 0;
    std::atomic<std::uint64_t> evictions_ = 0;
    std::atomic<std::uint64_t> denied_ = 0;
};

} // namespace metalcadence
