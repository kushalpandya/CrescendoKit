/*
 * ctaglib.cpp - Implementation of the C-API shim declared in ctaglib.h.
 *
 * Compiled by Scripts/build-taglib.sh and linked with a static libtag.a into
 * the dynamic CTagLib.framework. Parses one file into a shim-owned
 * `ctaglib_metadata` and exposes borrowed views of the copied-out values.
 *
 * Most tags come from TagLib's unified PropertyMap (one normalized key space
 * across all container formats); audio properties, pictures, and the ID3v2
 * POPM rating need format-specific access via dynamic_cast. dynamic_cast is
 * safe here: the shim and TagLib are linked into the same dynamic library, so
 * RTTI resolves intra-library despite hidden visibility.
 *
 * Every `extern "C"` entry point that touches untrusted data is wrapped in
 * try/catch: a C++ exception unwinding across the C boundary is undefined
 * behavior, so failures are caught and reported as a null/zero sentinel.
 */

#include "ctaglib.h"

#include <atomic>
#include <string>
#include <utility>
#include <vector>

#include "fileref.h"
#include "tfile.h"
#include "audioproperties.h"
#include "tstring.h"
#include "tstringlist.h"
#include "tpropertymap.h"
#include "tvariant.h"
#include "tbytevector.h"
#include "tlist.h"
#include "tdebuglistener.h"

// TagLib's tdebug.h is internal and not installed with the public headers,
// so declare the debug-channel entry point directly (signature mirrored from
// taglib/toolkit/tdebug.h). The definition exists in our libtag.a because
// build-taglib.sh compiles TagLib with -DTRACE_IN_RELEASE; the static link
// resolves it despite hidden visibility.
namespace TagLib {
void debug(const String &s);
} // namespace TagLib

// Format-specific properties, for codec name + bit depth.
#include "flacproperties.h"
#include "mp4properties.h"
#include "mpegproperties.h"
#include "vorbisproperties.h"
#include "opusproperties.h"
#include "wavproperties.h"
#include "aiffproperties.h"
#include "apeproperties.h"
#include "wavpackproperties.h"
#include "trueaudioproperties.h"
#include "mpcproperties.h"
#include "dsfproperties.h"
#include "dsdiffproperties.h"
#include "asfproperties.h"

// ID3v2 POPM rating (MP3 and other ID3v2 carriers).
#include "mpegfile.h"
#include "id3v2tag.h"
#include "popularimeterframe.h"

namespace {

// One embedded picture: the encoded bytes plus its MIME type, TagLib's
// canonical type string ("Front Cover", ...), and free-text description.
struct Picture {
    std::vector<unsigned char> data;
    std::string mime;
    std::string type;
    std::string description;
};

// Converts a TagLib::String to a UTF-8 std::string.
std::string toUtf8(const TagLib::String &s) {
    return s.to8Bit(true);
}

// Derives the codec/format name, bit depth, and lossless flag from the concrete
// AudioProperties subclass - i.e. from the actually-decoded codec, not the file
// extension. This is what lets us distinguish ALAC from AAC inside .m4a, WMA
// Lossless from lossy WMA, and lossless WavPack from its hybrid-lossy mode.
//   lossless: 1 = lossless, 0 = lossy, -1 = unknown.
void extractFormatInfo(const TagLib::AudioProperties *props,
                       bool &hasCodec, std::string &codec, int &bitsPerSample, int &lossless) {
    hasCodec = false;
    codec.clear();
    bitsPerSample = 0;
    lossless = -1;
    if (props == nullptr) {
        return;
    }

    if (const auto *p = dynamic_cast<const TagLib::FLAC::Properties *>(props)) {
        codec = "flac";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::MP4::Properties *>(props)) {
        const bool alac = p->codec() == TagLib::MP4::Properties::ALAC;
        codec = alac ? "alac" : "aac";
        bitsPerSample = p->bitsPerSample();
        lossless = alac ? 1 : 0;
    } else if (dynamic_cast<const TagLib::MPEG::Properties *>(props) != nullptr) {
        codec = "mp3";
        lossless = 0;
    } else if (dynamic_cast<const TagLib::Ogg::Vorbis::Properties *>(props) != nullptr) {
        codec = "vorbis";
        lossless = 0;
    } else if (dynamic_cast<const TagLib::Ogg::Opus::Properties *>(props) != nullptr) {
        codec = "opus";
        lossless = 0;
    } else if (const auto *p = dynamic_cast<const TagLib::RIFF::WAV::Properties *>(props)) {
        codec = "wav";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::RIFF::AIFF::Properties *>(props)) {
        codec = "aiff";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::APE::Properties *>(props)) {
        codec = "ape";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::WavPack::Properties *>(props)) {
        codec = "wavpack";
        bitsPerSample = p->bitsPerSample();
        lossless = p->isLossless() ? 1 : 0; // WavPack has a hybrid lossy mode
    } else if (const auto *p = dynamic_cast<const TagLib::TrueAudio::Properties *>(props)) {
        codec = "tta";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (dynamic_cast<const TagLib::MPC::Properties *>(props) != nullptr) {
        codec = "musepack";
        lossless = 0;
    } else if (const auto *p = dynamic_cast<const TagLib::DSF::Properties *>(props)) {
        codec = "dsf";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::DSDIFF::Properties *>(props)) {
        codec = "dsdiff";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::ASF::Properties *>(props)) {
        codec = "wma";
        lossless = (p->codec() == TagLib::ASF::Properties::WMA9Lossless) ? 1 : 0;
    }

    hasCodec = !codec.empty();
}

// Reads the ID3v2 POPM rating byte (0-255) if the file carries one.
void extractRating(TagLib::File *file, bool &hasRating, int &rating) {
    hasRating = false;
    rating = 0;

    auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file);
    if (mpeg == nullptr || !mpeg->hasID3v2Tag()) {
        return;
    }
    const TagLib::ID3v2::Tag *tag = mpeg->ID3v2Tag();
    if (tag == nullptr) {
        return;
    }
    const TagLib::ID3v2::FrameList &frames = tag->frameList("POPM");
    if (frames.isEmpty()) {
        return;
    }
    const auto *popm = dynamic_cast<const TagLib::ID3v2::PopularimeterFrame *>(frames.front());
    if (popm == nullptr) {
        return;
    }
    rating = popm->rating();
    hasRating = true;
}

} // namespace

// The opaque handle. Holds copies of every value so that accessors never reach
// back into TagLib objects (which are destroyed when the read returns).
struct ctaglib_metadata {
    double lengthSeconds = 0.0;
    int sampleRate = 0;
    int channels = 0;
    int bitrateKbps = 0;
    int bitsPerSample = 0;

    bool hasCodec = false;
    std::string codec;
    int lossless = -1; // 1 = lossless, 0 = lossy, -1 = unknown

    // The full TagLib PropertyMap, as ordered (key, [values]) pairs.
    std::vector<std::pair<std::string, std::vector<std::string>>> tags;

    std::vector<Picture> pictures;

    bool hasRating = false;
    int rating = 0;
};

namespace {

// Defensive bounds for untrusted input. A player scans whole libraries, so a
// single crafted or corrupt file must not be able to make the shim copy out
// unbounded memory. Real files sit far below all of these, so the caps only
// ever trip on pathological input. Reads stay raw and unnormalized otherwise:
// the caps drop excess, they do not transform.
constexpr size_t maxTagCount = 4096;                  // distinct property keys
constexpr size_t maxValuesPerTag = 1024;              // values under one key
constexpr size_t maxValueLength = 1024 * 1024;        // source chars per value
constexpr size_t maxPictureCount = 8;                 // attached pictures
// Matches the Swift reader's own per-picture cap exactly: copying more here
// would only hand Swift bytes it is guaranteed to reject (its cap is also
// enforced Swift-side so the protection holds against older shim builds).
constexpr size_t maxPictureBytes = 24 * 1024 * 1024;  // bytes per picture

// Copies the unified tag dictionary out of `file` into shim-owned storage,
// bounded by the caps above. Shared by the full and tags-only reads so the
// two can never diverge. An oversized individual value is dropped without
// converting it (the length check is on the source string, so a pathological
// value never forces a large UTF-8 conversion); a key left with no values is
// itself dropped rather than surfaced empty.
void copyProperties(TagLib::File *file, ctaglib_metadata *meta) {
    const TagLib::PropertyMap properties = file->properties();
    for (auto it = properties.begin(); it != properties.end(); ++it) {
        if (meta->tags.size() >= maxTagCount) {
            break;
        }
        std::vector<std::string> values;
        const TagLib::StringList &list = it->second;
        for (auto vit = list.begin(); vit != list.end(); ++vit) {
            if (values.size() >= maxValuesPerTag) {
                break;
            }
            if ((*vit).size() > maxValueLength) {
                continue;
            }
            values.push_back(toUtf8(*vit));
        }
        if (!values.empty()) {
            meta->tags.emplace_back(toUtf8(it->first), std::move(values));
        }
    }
}

// The single read body behind every public read variant: parses the file
// once and extracts only the sections selected in `options`. The FileRef is
// constructed without the audio-properties parse when they were not asked
// for; everything else TagLib reads is dictated by the container format, so
// the options gate the copy-out (and its allocations), not the file I/O.
ctaglib_metadata *readWithOptions(const char *path, uint32_t options) {
    if (path == nullptr) {
        return nullptr;
    }
    try {
        const bool wantProperties = (options & CTAGLIB_READ_AUDIO_PROPERTIES) != 0;
        // FileRef picks the right parser from the file's content/extension.
        TagLib::FileRef ref(path, wantProperties);
        TagLib::File *file = ref.file();
        if (ref.isNull() || file == nullptr) {
            return nullptr;
        }

        auto *meta = new ctaglib_metadata();

        if (wantProperties) {
            if (const TagLib::AudioProperties *props = ref.audioProperties()) {
                meta->lengthSeconds = props->lengthInMilliseconds() / 1000.0;
                meta->sampleRate = props->sampleRate();
                meta->channels = props->channels();
                meta->bitrateKbps = props->bitrate();
                extractFormatInfo(props, meta->hasCodec, meta->codec, meta->bitsPerSample, meta->lossless);
            }
        }

        if ((options & CTAGLIB_READ_TAGS) != 0) {
            copyProperties(file, meta);
        }

        // Attached pictures via the unified complex-properties API. Skip any
        // picture larger than the byte cap and stop after the count cap: cover
        // art is far smaller and far fewer in practice, and a corrupt or hostile
        // file encountered during a bulk scan must not be able to make us copy
        // out enormous or unboundedly many buffers.
        if ((options & CTAGLIB_READ_PICTURES) != 0) {
            const TagLib::List<TagLib::VariantMap> pictures = file->complexProperties("PICTURE");
            for (auto it = pictures.begin(); it != pictures.end(); ++it) {
                if (meta->pictures.size() >= maxPictureCount) {
                    break;
                }
                const TagLib::VariantMap &map = *it;
                const TagLib::ByteVector data = map.value("data").value<TagLib::ByteVector>();
                if (data.isEmpty() || data.size() > maxPictureBytes) {
                    continue;
                }
                Picture picture;
                picture.data.assign(
                    reinterpret_cast<const unsigned char *>(data.data()),
                    reinterpret_cast<const unsigned char *>(data.data()) + data.size());
                picture.mime = toUtf8(map.value("mimeType").value<TagLib::String>());
                picture.type = toUtf8(map.value("pictureType").value<TagLib::String>());
                picture.description = toUtf8(map.value("description").value<TagLib::String>());
                meta->pictures.push_back(std::move(picture));
            }
        }

        if ((options & CTAGLIB_READ_RATING) != 0) {
            extractRating(file, meta->hasRating, meta->rating);
        }

        return meta;
    } catch (...) {
        // Any parser failure on untrusted input becomes a clean NULL.
        return nullptr;
    }
}

} // namespace

extern "C" {

ctaglib_metadata *ctaglib_read(const char *path) {
    return readWithOptions(
        path,
        CTAGLIB_READ_AUDIO_PROPERTIES | CTAGLIB_READ_TAGS | CTAGLIB_READ_PICTURES | CTAGLIB_READ_RATING);
}

ctaglib_metadata *ctaglib_read_tags(const char *path) {
    return readWithOptions(path, CTAGLIB_READ_TAGS);
}

ctaglib_metadata *ctaglib_read_with(const char *path, uint32_t options) {
    return readWithOptions(path, options);
}

void ctaglib_metadata_free(ctaglib_metadata *meta) {
    delete meta;
}

double ctaglib_length_seconds(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->lengthSeconds : 0.0;
}

int ctaglib_sample_rate(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->sampleRate : 0;
}

int ctaglib_channels(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->channels : 0;
}

int ctaglib_bitrate_kbps(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->bitrateKbps : 0;
}

int ctaglib_bits_per_sample(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->bitsPerSample : 0;
}

int ctaglib_is_lossless(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->lossless : -1;
}

const char *ctaglib_codec(const ctaglib_metadata *meta, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || !meta->hasCodec) {
        *out_len = 0;
        return nullptr;
    }
    *out_len = meta->codec.size();
    return meta->codec.data();
}

size_t ctaglib_tag_count(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->tags.size() : 0;
}

const char *ctaglib_tag_key(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->tags.size()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &key = meta->tags[i].first;
    *out_len = key.size();
    return key.data();
}

size_t ctaglib_tag_value_count(const ctaglib_metadata *meta, size_t i) {
    if (meta == nullptr || i >= meta->tags.size()) {
        return 0;
    }
    return meta->tags[i].second.size();
}

const char *ctaglib_tag_value(const ctaglib_metadata *meta, size_t i, size_t j, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->tags.size() || j >= meta->tags[i].second.size()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &value = meta->tags[i].second[j];
    *out_len = value.size();
    return value.data();
}

size_t ctaglib_picture_count(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->pictures.size() : 0;
}

const unsigned char *ctaglib_picture_data(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->pictures.size()) {
        *out_len = 0;
        return nullptr;
    }
    const std::vector<unsigned char> &data = meta->pictures[i].data;
    *out_len = data.size();
    return data.data();
}

const char *ctaglib_picture_mime(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->pictures.size() || meta->pictures[i].mime.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &mime = meta->pictures[i].mime;
    *out_len = mime.size();
    return mime.data();
}

const char *ctaglib_picture_type(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->pictures.size() || meta->pictures[i].type.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &type = meta->pictures[i].type;
    *out_len = type.size();
    return type.data();
}

const char *ctaglib_picture_description(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->pictures.size() || meta->pictures[i].description.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &description = meta->pictures[i].description;
    *out_len = description.size();
    return description.data();
}

int ctaglib_has_rating(const ctaglib_metadata *meta) {
    return (meta != nullptr && meta->hasRating) ? 1 : 0;
}

int ctaglib_rating(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->rating : 0;
}

} // extern "C"

namespace {

// The installed sink. Atomic because reads run (and therefore emit) on any
// thread while the callback is installed once from another; the log path
// itself takes no locks.
std::atomic<ctaglib_log_callback> logCallback{nullptr};

// Adapts TagLib's listener interface to the C callback: converts to UTF-8,
// trims the trailing newline TagLib appends, and forwards. A message
// arriving while the callback is being cleared is dropped by the load.
class CallbackDebugListener : public TagLib::DebugListener {
public:
    void printMessage(const TagLib::String &msg) override {
        const ctaglib_log_callback callback = logCallback.load(std::memory_order_acquire);
        if (callback == nullptr) {
            return;
        }
        const std::string utf8 = toUtf8(msg);
        size_t length = utf8.size();
        while (length > 0 && (utf8[length - 1] == '\n' || utf8[length - 1] == '\r')) {
            --length;
        }
        if (length == 0) {
            return;
        }
        callback(utf8.data(), length);
    }
};

CallbackDebugListener bridgeListener;

} // namespace

extern "C" {

void ctaglib_set_log_callback(ctaglib_log_callback callback) {
    logCallback.store(callback, std::memory_order_release);
    // NULL restores TagLib's default stderr listener (setDebugListener's
    // documented null behavior).
    TagLib::setDebugListener(callback != nullptr ? &bridgeListener : nullptr);
}

void ctaglib_emit_debug(const char *message) {
    if (message == nullptr) {
        return;
    }
    TagLib::debug(TagLib::String(message, TagLib::String::UTF8));
}

} // extern "C"
