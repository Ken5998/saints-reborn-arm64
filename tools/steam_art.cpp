// Draws the Steam library artwork for Saints Reborn from its own logo and icon
// (both in Saints Reborn's repository, Apache 2.0, read from the player's
// checkout; none of it is stored here):
//
//   steam_art LOGO.png ICON.ico OUTDIR
//
// OUTDIR gets capsule.png (600x900), wide.png (920x430), hero.png (1920x620),
// logo.png and icon.png, the names add-to-steam.py expects. Built by
// add-to-steam.sh with the port's toolchain, against the SDK's stb_image and
// the sysroot's zlib.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "stb_image.h"

#include <zlib.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {

// Premultiplied RGBA, 0..1.
struct Image {
    int w = 0, h = 0;
    std::vector<float> px;
    Image() = default;
    Image(int width, int height) : w(width), h(height), px(size_t(width) * height * 4, 0.0f) {}
    float* at(int x, int y) { return &px[(size_t(y) * w + x) * 4]; }
    const float* at(int x, int y) const { return &px[(size_t(y) * w + x) * 4]; }
};

std::vector<uint8_t> ReadFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

bool Decode(const uint8_t* data, size_t size, Image& out) {
    int w, h, n;
    stbi_uc* rgba = stbi_load_from_memory(data, int(size), &w, &h, &n, 4);
    if (!rgba) return false;
    out = Image(w, h);
    for (size_t i = 0; i < size_t(w) * h; ++i) {
        const float a = rgba[i * 4 + 3] / 255.0f;
        for (int c = 0; c < 3; ++c) out.px[i * 4 + c] = rgba[i * 4 + c] / 255.0f * a;
        out.px[i * 4 + 3] = a;
    }
    stbi_image_free(rgba);
    return true;
}

// The largest PNG picture in a Windows .ico.
bool DecodeIco(const std::vector<uint8_t>& ico, Image& out, std::vector<uint8_t>& png) {
    if (ico.size() < 6) return false;
    const int count = ico[4] | ico[5] << 8;
    size_t best = 0;
    for (int i = 0; i < count && 6 + 16 * (i + 1) <= int(ico.size()); ++i) {
        const uint8_t* e = &ico[6 + 16 * i];
        const uint32_t size = e[8] | e[9] << 8 | e[10] << 16 | uint32_t(e[11]) << 24;
        const uint32_t offset = e[12] | e[13] << 8 | e[14] << 16 | uint32_t(e[15]) << 24;
        if (size_t(offset) + size > ico.size() || size < 8 || ico[offset] != 0x89) continue;
        const int side = e[0] ? e[0] : 256;
        if (size_t(side) > best) {
            best = side;
            png.assign(ico.begin() + offset, ico.begin() + offset + size);
        }
    }
    return best && Decode(png.data(), png.size(), out);
}

// Separable resampling with a tent filter widened to the scale when shrinking
// (an area average), plain bilinear when growing.
Image ResizeAxis(const Image& src, int w, int h, bool horizontal) {
    Image dst(w, h);
    const int in_len = horizontal ? src.w : src.h, out_len = horizontal ? w : h;
    const float scale = float(in_len) / out_len, support = std::max(1.0f, scale);
    std::vector<std::vector<std::pair<int, float>>> taps(out_len);
    for (int o = 0; o < out_len; ++o) {
        const float center = (o + 0.5f) * scale - 0.5f;
        const int lo = int(std::floor(center - support)), hi = int(std::ceil(center + support));
        float total = 0;
        for (int i = lo; i <= hi; ++i) {
            const float weight = std::max(0.0f, 1.0f - std::fabs(i - center) / support);
            if (weight <= 0) continue;
            taps[o].push_back({std::clamp(i, 0, in_len - 1), weight});
            total += weight;
        }
        for (auto& tap : taps[o]) tap.second /= total;
    }
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            float* d = dst.at(x, y);
            for (const auto& [i, weight] : taps[horizontal ? x : y]) {
                const float* s = horizontal ? src.at(i, y) : src.at(x, i);
                for (int c = 0; c < 4; ++c) d[c] += s[c] * weight;
            }
        }
    }
    return dst;
}

Image Resize(const Image& src, int w, int h) {
    return ResizeAxis(ResizeAxis(src, w, src.h, true), w, h, false);
}

Image ScaleToWidth(const Image& src, int w) {
    return Resize(src, w, std::max(1, int(std::lround(double(src.h) * w / src.w))));
}

// Three box blurs, close to a gaussian.
Image Blur(Image img, int radius) {
    for (int pass = 0; pass < 6; ++pass) {
        const bool horizontal = pass % 2 == 0;
        Image out(img.w, img.h);
        const int lines = horizontal ? img.h : img.w, len = horizontal ? img.w : img.h;
        for (int l = 0; l < lines; ++l) {
            float sum[4] = {};
            auto px = [&](int i) { return horizontal ? img.at(std::clamp(i, 0, len - 1), l)
                                                     : img.at(l, std::clamp(i, 0, len - 1)); };
            for (int i = -radius; i <= radius; ++i)
                for (int c = 0; c < 4; ++c) sum[c] += px(i)[c];
            for (int i = 0; i < len; ++i) {
                float* d = horizontal ? out.at(i, l) : out.at(l, i);
                for (int c = 0; c < 4; ++c) d[c] = sum[c] / (2 * radius + 1);
                for (int c = 0; c < 4; ++c) sum[c] += px(i + radius + 1)[c] - px(i - radius)[c];
            }
        }
        img = std::move(out);
    }
    return img;
}

// src over dst, centered at (cx, cy).
void Over(Image& dst, const Image& src, int cx, int cy, float opacity = 1.0f) {
    const int x0 = cx - src.w / 2, y0 = cy - src.h / 2;
    for (int y = std::max(0, -y0); y < src.h && y0 + y < dst.h; ++y) {
        for (int x = std::max(0, -x0); x < src.w && x0 + x < dst.w; ++x) {
            const float* s = src.at(x, y);
            float* d = dst.at(x0 + x, y0 + y);
            const float a = s[3] * opacity;
            for (int c = 0; c < 4; ++c) d[c] = s[c] * opacity + d[c] * (1 - a);
        }
    }
}

// Near black with a deep red glow around (gx, gy), darker at the edges.
Image Background(int w, int h, float gx, float gy, float radius) {
    Image img(w, h);
    const float base[3] = {0.045f, 0.035f, 0.045f}, glow[3] = {0.50f, 0.035f, 0.07f};
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const float dx = (x - gx) / radius, dy = (y - gy) / radius;
            const float g = std::exp(-2.2f * (dx * dx + dy * dy));
            const float ex = 2.0f * x / w - 1, ey = 2.0f * y / h - 1;
            const float vignette = 1.0f - 0.45f * std::min(1.0f, 0.5f * (ex * ex + ey * ey));
            float* d = img.at(x, y);
            for (int c = 0; c < 3; ++c) d[c] = (base[c] + glow[c] * g) * vignette;
            d[3] = 1;
        }
    }
    return img;
}

void Put32(std::vector<uint8_t>& out, uint32_t v) {
    for (int s = 24; s >= 0; s -= 8) out.push_back(uint8_t(v >> s));
}

void Chunk(std::vector<uint8_t>& png, const char* type, const std::vector<uint8_t>& data) {
    Put32(png, uint32_t(data.size()));
    const size_t start = png.size();
    png.insert(png.end(), type, type + 4);
    png.insert(png.end(), data.begin(), data.end());
    Put32(png, uint32_t(crc32(0, &png[start], uInt(png.size() - start))));
}

bool WritePng(const std::string& path, const Image& img, bool alpha) {
    const int channels = alpha ? 4 : 3;
    std::vector<uint8_t> raw;
    raw.reserve(size_t(img.w * channels + 1) * img.h);
    uint32_t noise = 0x9E3779B9u;
    for (int y = 0; y < img.h; ++y) {
        raw.push_back(0);  // filter: none
        for (int x = 0; x < img.w; ++x) {
            const float* p = img.at(x, y);
            const float a = p[3];
            for (int c = 0; c < channels; ++c) {
                float v = c == 3 ? a : (a > 0 ? p[c] / a : 0);
                // A little noise, so the dark gradients do not band.
                noise = noise * 1664525u + 1013904223u;
                v = v * 255.0f + (noise >> 8) / float(1 << 24) - 0.5f;
                raw.push_back(uint8_t(std::clamp(std::lround(v), 0L, 255L)));
            }
        }
    }
    uLongf size = compressBound(uLong(raw.size()));
    std::vector<uint8_t> packed(size);
    if (compress2(packed.data(), &size, raw.data(), uLong(raw.size()), 9) != Z_OK) return false;
    packed.resize(size);

    std::vector<uint8_t> png = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    std::vector<uint8_t> header;
    Put32(header, uint32_t(img.w));
    Put32(header, uint32_t(img.h));
    header.insert(header.end(), {8, uint8_t(alpha ? 6 : 2), 0, 0, 0});
    Chunk(png, "IHDR", header);
    Chunk(png, "IDAT", packed);
    Chunk(png, "IEND", {});
    std::ofstream out(path, std::ios::binary);
    out.write(reinterpret_cast<const char*>(png.data()), std::streamsize(png.size()));
    return bool(out);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 4) {
        std::fprintf(stderr, "usage: steam_art LOGO.png ICON.ico OUTDIR\n");
        return 2;
    }
    const std::string out = argv[3];
    const std::vector<uint8_t> logo_file = ReadFile(argv[1]), ico_file = ReadFile(argv[2]);
    Image logo, emblem;
    std::vector<uint8_t> icon_png;
    if (!Decode(logo_file.data(), logo_file.size(), logo) || !DecodeIco(ico_file, emblem, icon_png)) {
        std::fprintf(stderr, "steam_art: cannot read %s or %s\n", argv[1], argv[2]);
        return 1;
    }

    // Portrait capsule: the emblem over a soft, larger copy of itself, the
    // logo below.
    Image capsule = Background(600, 900, 300, 330, 430);
    Over(capsule, Blur(Resize(emblem, 640, 640), 14), 300, 330, 0.20f);
    Over(capsule, Resize(emblem, 330, 330), 300, 330);
    Over(capsule, ScaleToWidth(logo, 560), 300, 690);

    // Wide capsule: the logo.
    Image wide = Background(920, 430, 460, 215, 420);
    Over(wide, Blur(Resize(emblem, 470, 470), 12), 460, 215, 0.16f);
    Over(wide, ScaleToWidth(logo, 780), 460, 220);

    // Hero: Steam puts the logo over its left side, so the emblem sits right.
    Image hero = Background(1920, 620, 1460, 300, 700);
    Over(hero, Blur(Resize(emblem, 900, 900), 18), 1460, 310, 0.22f);
    Over(hero, Resize(emblem, 470, 470), 1460, 310);

    const bool ok = WritePng(out + "/capsule.png", capsule, false) &&
                    WritePng(out + "/wide.png", wide, false) &&
                    WritePng(out + "/hero.png", hero, false) &&
                    WritePng(out + "/logo.png", ScaleToWidth(logo, 1280), true);
    std::ofstream icon(out + "/icon.png", std::ios::binary);
    icon.write(reinterpret_cast<const char*>(icon_png.data()), std::streamsize(icon_png.size()));
    if (!ok || !icon) {
        std::fprintf(stderr, "steam_art: cannot write to %s\n", out.c_str());
        return 1;
    }
    std::printf("Steam artwork in %s\n", out.c_str());
    return 0;
}
